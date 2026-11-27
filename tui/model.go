package main

import (
	"context"
	"slices"
	"strings"
	"time"
	"unicode"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

type page uint8

const (
	queuePage page = iota
	agentsPage
	timelinePage
)

const initialPollDelay = 2 * time.Second

type pollTick struct{}
type spriteTick time.Time

const (
	workFrameInterval = 120 * time.Millisecond
	restFrameInterval = 600 * time.Millisecond
)

type spriteMotion struct {
	kind  motion
	since time.Time
}

type pollResult struct {
	snapshot   snapshot
	err        error
	detail     ticketDetail
	detailID   string
	detailErr  error
	receivedAt time.Time
}

type model struct {
	ctx     context.Context
	client  consoleClient
	opt     options
	palette palette
	assets  artwork

	width       int
	height      int
	page        page
	inspect     bool
	filtering   bool
	filter      textinput.Model
	scroll      int
	showHelp    bool
	selected    string
	tickets     []ticket
	detail      ticketDetail
	detailErr   error
	snapshot    snapshot
	lastSuccess time.Time
	lastErr     error
	pollDelay   time.Duration

	motions      map[string]spriteMotion
	spriteAt     time.Time
	spriteQueued bool
}

func newModel(ctx context.Context, client consoleClient, opt options) model {
	filter := textinput.New()
	filter.Placeholder = "Issue, project, state or agent"
	filter.Prompt = "/ "
	filter.CharLimit = 100
	filter.SetWidth(30)
	m := model{
		ctx:       ctx,
		client:    client,
		opt:       opt,
		palette:   newPalette(opt.theme == "light"),
		assets:    providerAssets(opt),
		width:     80,
		height:    24,
		filter:    filter,
		pollDelay: initialPollDelay,
	}
	m.updateMotions(time.Now(), nil)
	return m
}

func (m model) Init() tea.Cmd {
	if m.opt.theme == "auto" && !m.opt.monochrome {
		return tea.Batch(m.poll(), tea.RequestBackgroundColor)
	}
	return m.poll()
}

// A poll owns both GETs. The next poll is scheduled only after both return.
func (m model) poll() tea.Cmd {
	return func() tea.Msg {
		state, err := m.client.state(m.ctx)
		result := pollResult{snapshot: state, err: err, receivedAt: time.Now()}
		if err == nil && state.hasIssue(m.selected) {
			result.detailID = m.selected
			result.detail, result.detailErr = m.client.issue(m.ctx, m.selected)
		}
		return result
	}
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var command tea.Cmd
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.filter.SetWidth(max(1, min(40, m.width-6)))
	case tea.BackgroundColorMsg:
		if m.opt.theme == "auto" {
			m.palette = newPalette(!msg.IsDark())
		}
	case pollTick:
		command = m.poll()
	case pollResult:
		m.receivePoll(msg)
		command = tea.Tick(m.pollDelay, func(time.Time) tea.Msg { return pollTick{} })
	case spriteTick:
		m.spriteQueued = false
		if at := time.Time(msg); at.After(m.spriteAt) {
			m.spriteAt = at
		}
	case tea.KeyPressMsg:
		m, command = m.handleKey(msg)
	case tea.MouseClickMsg:
		m.click(msg.Mouse())
	case tea.MouseWheelMsg:
		m.wheel(msg.Mouse())
	}
	if tick := m.scheduleSpriteTick(); tick != nil {
		if command == nil {
			return m, tick
		}
		return m, tea.Batch(command, tick)
	}
	return m, command
}

func (m *model) receivePoll(result pollResult) {
	m.lastErr = result.err
	if result.err != nil {
		m.updateMotions(result.receivedAt, nil)
		m.pollDelay = min(m.pollDelay*2, 20*time.Second)
		return
	}

	m.snapshot = result.snapshot
	m.tickets = sortedTickets(result.snapshot)
	m.updateMotions(result.receivedAt, m.tickets)
	m.lastSuccess = result.receivedAt
	m.pollDelay = initialPollDelay
	m.keepSelection()
	if m.selected != "" && result.detailID == m.selected {
		m.detail = result.detail
		m.detailErr = result.detailErr
	}
}

func (m *model) updateMotions(at time.Time, tickets []ticket) {
	if m.opt.noMotion || len(m.assets.sprites) == 0 {
		m.motions = nil
		return
	}
	kinds := runningMotions(tickets)
	next := make(map[string]spriteMotion, len(m.assets.sprites))
	for provider, art := range m.assets.sprites {
		kind := kinds[provider]
		if kind == motionReview && len(art.review) == 0 {
			kind = motionWork
		}
		if len(art.frames(kind)) == 0 {
			continue
		}
		current, exists := m.motions[provider]
		if !exists || current.kind != kind {
			current = spriteMotion{kind: kind, since: at}
		}
		next[provider] = current
	}
	m.motions = next
	// A delayed poll result must not move the clock backwards.
	if at.After(m.spriteAt) {
		m.spriteAt = at
	}
}

func (m *model) scheduleSpriteTick() tea.Cmd {
	cardsVisible := m.showStrip() || (m.page == agentsPage && m.width >= 30 && m.height >= 8)
	if m.spriteQueued || len(m.motions) == 0 || !cardsVisible {
		return nil
	}

	delay := restFrameInterval
	for _, current := range m.motions {
		if current.kind != motionRest {
			delay = workFrameInterval
			break
		}
	}
	m.spriteQueued = true
	return tea.Tick(delay, func(at time.Time) tea.Msg { return spriteTick(at) })
}

func (m model) sprite(provider string) []string {
	art := m.assets.sprites[provider]
	current, ok := m.motions[provider]
	if !ok {
		return art.still
	}
	frames := art.frames(current.kind)
	interval := workFrameInterval
	if current.kind == motionRest {
		interval = restFrameInterval
	}
	step := max(0, m.spriteAt.Sub(current.since)) / interval
	return frames[int(step)%len(frames)]
}

func sortedTickets(state snapshot) []ticket {
	rows := make([]ticket, 0, len(state.Blocked)+len(state.Running)+len(state.Retrying))
	groups := []struct {
		status string
		rows   []ticket
	}{
		{status: "Blocked", rows: state.Blocked},
		{status: "Running", rows: state.Running},
		{status: "Retrying", rows: state.Retrying},
	}
	seen := make(map[string]bool)
	for _, group := range groups {
		items := slices.Clone(group.rows)
		slices.SortFunc(items, func(a, b ticket) int { return strings.Compare(a.key(), b.key()) })
		for _, row := range items {
			key := row.key()
			if row.ID != "" && !seen[key] {
				row.Status = group.status
				rows = append(rows, row)
				seen[key] = true
			}
		}
	}
	return rows
}

func (state snapshot) hasIssue(id string) bool {
	if id == "" {
		return false
	}
	match := func(t ticket) bool { return t.key() == id }
	return slices.ContainsFunc(state.Blocked, match) || slices.ContainsFunc(state.Running, match) ||
		slices.ContainsFunc(state.Retrying, match)
}

func runningMotions(tickets []ticket) map[string]motion {
	kinds := make(map[string]motion)
	for _, t := range tickets {
		provider := providerKey(t.Provider)
		if provider == "" || t.Status != "Running" {
			continue
		}
		kind := motionWork
		words := strings.FieldsFunc(strings.ToLower(t.State), func(r rune) bool {
			return !unicode.IsLetter(r)
		})
		if slices.Contains(words, "review") {
			kind = motionReview
		}
		kinds[provider] = max(kinds[provider], kind)
	}
	return kinds
}

func (m model) handleKey(msg tea.KeyPressMsg) (model, tea.Cmd) {
	if msg.String() == "ctrl+c" {
		return m, tea.Quit
	}
	if m.filtering {
		switch msg.String() {
		case "esc":
			m.filter.Reset()
			m.filtering = false
			m.filter.Blur()
		case "enter":
			m.filtering = false
			m.filter.Blur()
		default:
			var command tea.Cmd
			m.filter, command = m.filter.Update(msg)
			m.keepSelection()
			return m, command
		}
		m.keepSelection()
		return m, nil
	}

	switch msg.String() {
	case "q":
		return m, tea.Quit
	case "?":
		m.showHelp = !m.showHelp
	case "esc":
		if m.page == queuePage && !m.inspect && m.filter.Value() != "" {
			m.filter.Reset()
			m.keepSelection()
		} else {
			m.showHelp, m.inspect = false, false
			m.setPage(queuePage)
		}
	case "1":
		m.setPage(queuePage)
	case "2":
		m.setPage(agentsPage)
	case "3":
		m.setPage(timelinePage)
	case "/":
		m.setPage(queuePage)
		m.inspect = false
		m.filtering = true
		return m, m.filter.Focus()
	case "tab":
		if m.page == queuePage && m.selected != "" {
			m.inspect = !m.inspect
		} else {
			m.setPage((m.page + 1) % 3)
		}
	case "enter", "right":
		if m.page == queuePage && m.selected != "" {
			m.inspect = true
		}
	case "left":
		if m.page == queuePage {
			m.inspect = false
		}
	case "up", "k":
		if m.page == queuePage && !m.inspect {
			m.move(-1)
		} else {
			m.scrollBy(-1)
		}
	case "down", "j":
		if m.page == queuePage && !m.inspect {
			m.move(1)
		} else {
			m.scrollBy(1)
		}
	case "pgup":
		m.scrollBy(-max(1, m.bodyHeight()/2))
	case "pgdown":
		m.scrollBy(max(1, m.bodyHeight()/2))
	}
	return m, nil
}

func (m *model) setPage(page page) {
	m.page = page
	m.scroll = 0
}

func (m model) inBody(mouse tea.Mouse) bool {
	top := m.bodyTop()
	return m.width >= 30 && m.height >= 8 &&
		mouse.X >= 0 && mouse.X < m.width && mouse.Y >= top && mouse.Y < top+m.bodyHeight()
}

func (m model) overQueue(x int) bool {
	return m.page == queuePage && (m.width >= 100 && x < m.queueWidth() || m.width < 100 && !m.inspect)
}

func (m *model) click(mouse tea.Mouse) {
	if mouse.Button != tea.MouseLeft || m.width < 30 || m.height < 8 {
		return
	}
	if mouse.Y == 0 {
		labels := m.navLabels()
		start := m.navStart(labels)
		for index, label := range labels {
			if mouse.X >= start && mouse.X < start+len(label) {
				m.filtering = false
				m.filter.Blur()
				m.setPage(page(index))
				return
			}
			start += len(label) + 2
		}
	}
	if !m.inBody(mouse) || !m.overQueue(mouse.X) {
		return
	}
	rows := m.visibleQueueRows(m.filtered())
	index := mouse.Y - m.bodyTop() - 1
	if index >= 0 && index < len(rows) {
		m.filtering = false
		m.filter.Blur()
		m.selectTicket(rows[index].key())
		m.inspect = m.width < 100
	}
}

func (m *model) wheel(mouse tea.Mouse) {
	if !m.inBody(mouse) {
		return
	}
	delta := 3
	switch mouse.Button {
	case tea.MouseWheelUp:
		delta = -delta
	case tea.MouseWheelDown:
	default:
		return
	}
	if m.overQueue(mouse.X) {
		m.move(delta)
	} else {
		m.scrollBy(delta)
	}
}

func (m *model) move(offset int) {
	rows := m.filtered()
	current := slices.IndexFunc(rows, func(t ticket) bool { return t.key() == m.selected })
	if current >= 0 {
		m.selectTicket(rows[max(0, min(len(rows)-1, current+offset))].key())
	}
}

func (m *model) keepSelection() {
	rows := m.filtered()
	if slices.ContainsFunc(rows, func(t ticket) bool { return t.key() == m.selected }) {
		return
	}
	first := ""
	if len(rows) > 0 {
		first = rows[0].key()
	}
	m.selectTicket(first)
}

func (m *model) selectTicket(id string) {
	if id != m.selected {
		m.selected, m.detail, m.detailErr = id, ticketDetail{}, nil
		m.scroll = 0
	}
}

func (m model) filtered() []ticket {
	query := strings.ToLower(strings.TrimSpace(m.filter.Value()))
	if query == "" {
		return m.tickets
	}
	var result []ticket
	for _, t := range m.tickets {
		search := strings.Join([]string{t.ID, t.Project, t.Title, t.State, t.Status, providerName(t.Provider)}, " ")
		if strings.Contains(strings.ToLower(search), query) {
			result = append(result, t)
		}
	}
	return result
}

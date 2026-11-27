package main

import (
	"encoding/json"
	"fmt"
	"image/color"
	"slices"
	"strings"
	"time"
	"unicode"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

type palette struct {
	text, muted, accent, info, warning, rail, selected, border color.Color
}

func newPalette(light bool) palette {
	if light {
		return palette{
			lipgloss.Color("#18251c"), lipgloss.Color("#526254"),
			lipgloss.Color("#22613b"), lipgloss.Color("#195d84"), lipgloss.Color("#7b510b"),
			lipgloss.Color("#e9f0e9"), lipgloss.Color("#d9e9dd"), lipgloss.Color("#8ba391"),
		}
	}
	return palette{
		lipgloss.Color("#e6f1e7"), lipgloss.Color("#9dad9f"),
		lipgloss.Color("#a9dfb6"), lipgloss.Color("#a5cbea"), lipgloss.Color("#f1ce84"),
		lipgloss.Color("#19241c"), lipgloss.Color("#263b2d"), lipgloss.Color("#536b59"),
	}
}

func (m model) View() tea.View {
	view := tea.NewView(m.render())
	view.AltScreen = !m.opt.noAltScreen
	return view
}

func (m model) render() string {
	if m.width < 30 || m.height < 8 {
		return m.clip("Resize terminal   q close", m.width)
	}

	lines := m.header()
	if m.showStrip() {
		lines = append(lines, m.agentStrip()...)
	}
	if m.showFilter() {
		lines = append(lines, m.filterLine())
	}
	lines = append(lines, m.body()...)
	lines = append(lines, m.footer()...)
	return strings.Join(lines, "\n")
}

func (m model) header() []string {
	labels := []string{"1 Queue", "2 Agents", "3 Timeline"}
	if m.width < 58 {
		labels = []string{"1 Q", "2 A", "3 T"}
	}
	for index, label := range labels {
		if page(index) == m.page {
			labels[index] = m.paint(label, m.palette.accent, nil, true)
		}
	}
	nav := strings.Join(labels, "  ")
	name := m.paint(">_  SYMPHONY", m.palette.text, nil, true)
	top := name + strings.Repeat(" ", max(2, m.width-4-ansi.StringWidth(name)-ansi.StringWidth(nav))) + nav

	var health string
	switch {
	case m.lastErr != nil && !m.lastSuccess.IsZero():
		health = "Stale snapshot " + m.snapshot.GeneratedAt.Local().Format("15:04:05") + "  " + m.lastErr.Error()
	case m.lastErr != nil:
		health = "Offline  " + m.lastErr.Error()
	case m.lastSuccess.IsZero():
		health = "Connecting to local daemon"
	default:
		health = "Connected  " + m.snapshot.GeneratedAt.Local().Format("15:04:05")
	}
	healthColor := m.palette.accent
	if m.lastErr != nil {
		healthColor = m.palette.warning
	}
	return []string{
		m.fill("  "+top, m.width, m.palette.rail, m.palette.text, false),
		"  " + m.paint(m.clip(health, m.width-2), healthColor, nil, false),
	}
}

func (m model) showStrip() bool {
	return m.width >= 74 && m.height >= m.stripCardHeight()+14
}

func (m model) stripCardHeight() int {
	if len(m.assets.sprites) == 0 {
		return 3
	}
	if (m.width-2)/len(providers) < 32 {
		return artHeight + 3
	}
	return artHeight
}

func (m model) agentStrip() []string {
	cardWidth := (m.width - 2) / len(providers)
	separator := m.paint(m.glyph("│", "|"), m.palette.border, nil, false)
	horizontal := m.paint(strings.Repeat(m.glyph("─", "-"), m.width), m.palette.border, nil, false)
	cards := make([][]string, len(providers))
	for index, provider := range providers {
		width := cardWidth
		if index == len(providers)-1 {
			width = m.width - 2 - 2*cardWidth
		}
		cards[index] = m.providerCard(provider, width, m.stripCardHeight())
	}
	lines := []string{horizontal}
	for y := range m.stripCardHeight() {
		var row []string
		for _, card := range cards {
			row = append(row, card[y])
		}
		lines = append(lines, strings.Join(row, separator))
	}
	return append(lines, horizontal)
}

func (m model) providerCard(provider providerInfo, width, height int) []string {
	art := m.sprite(provider.key)
	if len(art) == 0 {
		art = make([]string, artHeight)
		art[artHeight/2] = m.center("["+provider.abbreviation+"]", artWidth)
	}
	tone := m.palette.muted
	if m.motions[provider.key].kind != motionRest {
		tone = m.palette.accent
	}
	status, modelLabel := m.providerStatus(provider.key)
	labels := []string{
		m.paint(provider.name, m.palette.text, nil, true),
		m.paint(status, tone, nil, false),
		m.paint(modelLabel, m.palette.muted, nil, false),
	}
	rows := make([]string, height)
	if height != artHeight {
		if height > len(labels) {
			for y, line := range art {
				rows[y] = m.center(line, width)
			}
		}
		for y, label := range labels {
			rows[height-len(labels)+y] = m.center(label, width)
		}
		return rows
	}

	firstLabel := (artHeight - len(labels)) / 2
	for y := range rows {
		line := " " + m.pad(art[y], artWidth) + " "
		if index := y - firstLabel; index >= 0 && index < len(labels) {
			line += labels[index]
		}
		rows[y] = m.pad(line, width)
	}
	return rows
}

func (m model) center(line string, width int) string {
	line = m.clip(line, width)
	return m.pad(strings.Repeat(" ", (width-ansi.StringWidth(line))/2)+line, width)
}

func (m model) providerStatus(provider string) (string, string) {
	if m.lastSuccess.IsZero() || m.lastErr != nil {
		return "Status unknown", ""
	}
	var active []ticket
	for _, row := range m.tickets {
		if row.Provider == provider {
			active = append(active, row)
		}
	}
	if len(active) == 0 {
		return "No session", ""
	}
	if len(active) > 1 {
		return fmt.Sprintf("%d observed tickets", len(active)), ""
	}
	row := active[0]
	modelLabel := strings.TrimSpace(clean(row.Model + " " + row.Effort))
	if modelLabel == "" {
		modelLabel = clean(row.State)
	}
	return row.Status + "  " + clean(row.ID), modelLabel
}

func (m model) showFilter() bool {
	return m.page == queuePage && (m.filtering || m.filter.Value() != "")
}

func (m model) filterLine() string {
	if m.filtering {
		return "  " + m.clip(m.filter.View(), m.width-2)
	}
	return "  " + m.clip("Filter  "+clean(m.filter.Value()), m.width-2)
}

func (m model) bodyHeight() int {
	height := m.height - 3
	if m.showHelp {
		height -= 2
	}
	if m.showStrip() {
		height -= m.stripCardHeight() + 2
	}
	if m.showFilter() {
		height--
	}
	return max(1, height)
}

func (m model) body() []string {
	height := m.bodyHeight()
	switch m.page {
	case agentsPage, timelinePage:
		return fit(m.scrollableLines(), height, m.scroll)
	}
	if m.width >= 100 {
		left := m.queueWidth()
		queue := fit(m.queueLines(left), height, 0)
		detail := fit(m.scrollableLines(), height, m.scroll)
		divider := m.paint(m.glyph("│", "|"), m.palette.border, nil, false)
		lines := make([]string, height)
		for y := range lines {
			lines[y] = m.pad(queue[y], left) + divider + detail[y]
		}
		return lines
	}
	if m.inspect {
		return fit(m.scrollableLines(), height, m.scroll)
	}
	return fit(m.queueLines(m.width), height, 0)
}

func (m model) queueWidth() int {
	return min(40, m.width/3)
}

func (m model) queueLines(width int) []string {
	rows := m.filtered()
	status, heading := "", "WORK QUEUE"
	if !m.inspect {
		heading = "> " + heading
	}
	title := fmt.Sprintf("%s  %d", heading, len(rows))
	lines := []string{m.fill("  "+title, width, m.palette.rail, m.palette.text, true)}
	if len(rows) == 0 {
		switch {
		case m.filter.Value() != "":
			status = "No matching tickets"
		case m.lastSuccess.IsZero():
			status = "Waiting for snapshot"
		default:
			status = "No running, retrying or blocked tickets"
		}
		return append(lines, "  "+m.clip(status, width-2))
	}

	current := slices.IndexFunc(rows, func(t ticket) bool { return t.ID == m.selected })
	offset := max(0, current-m.bodyHeight()+2)
	for _, row := range rows[offset:] {
		tone := m.palette.text
		if row.Status == "Blocked" {
			tone = m.palette.warning
		}
		marker := "  "
		var background color.Color
		if row.ID == m.selected {
			marker, background = "> ", m.palette.selected
		}
		state := clean(row.Status)
		label := clean(row.ID)
		if width >= 48 && row.State != "" {
			label += "  " + clean(row.State)
		}
		gap := max(1, width-3-ansi.StringWidth(label)-ansi.StringWidth(state))
		label = m.clip(label, max(1, width-4-ansi.StringWidth(state)))
		lines = append(lines, m.fill(marker+label+strings.Repeat(" ", gap)+state, width, background, tone, row.ID == m.selected))
	}
	return lines
}

func (m model) selectedTicket() (ticket, bool) {
	i := slices.IndexFunc(m.tickets, func(t ticket) bool { return t.ID == m.selected })
	if i < 0 {
		return ticket{}, false
	}
	row := m.tickets[i]
	var observed *ticket
	if m.detail.ID == row.ID && strings.EqualFold(m.detail.Status, row.Status) {
		switch row.Status {
		case "Running":
			observed = m.detail.Running
		case "Blocked":
			observed = m.detail.Blocked
		case "Retrying":
			observed = m.detail.Retry
		}
	}
	if observed != nil {
		if row.Reason == "" {
			row.Reason = m.detail.Error
		}
		if row.Provider == "" {
			row.Provider = observed.Provider
		}
	}
	return row, true
}

func (m model) scrollableLines() []string {
	width := m.width
	if m.page == queuePage && width >= 100 {
		width -= m.queueWidth() + 1
	}
	switch m.page {
	case agentsPage:
		return m.agentLines(width)
	case timelinePage:
		return m.timelineLines(width)
	default:
		return m.issueLines(width)
	}
}

func (m *model) scrollBy(delta int) {
	limit := max(0, len(m.scrollableLines())-m.bodyHeight())
	m.scroll = max(0, min(limit, m.scroll+delta))
}

func (m model) issueLines(width int) []string {
	row, found := m.selectedTicket()
	if !found {
		return []string{m.sectionHeading("INSPECTOR", width), "  Select a ticket to inspect"}
	}
	heading := clean(row.ID)
	if row.Title != "" {
		heading += "  " + clean(row.Title)
	}
	if m.inspect {
		heading = "> " + heading
	}
	lines := []string{m.sectionHeading(heading, width), ""}
	lines = m.appendField(lines, "Status", row.Status, width)
	lines = m.appendField(lines, "Tracker state", row.State, width)
	lines = m.appendField(lines, "Provider", providerName(row.Provider), width)
	lines = m.appendField(lines, "Model", row.Model, width)
	lines = m.appendField(lines, "Effort", row.Effort, width)
	lines = m.appendField(lines, "Profile", row.Profile, width)
	lines = m.appendField(lines, "Session", row.Session, width)
	// The legacy API supplies Codex counters even on non-Codex entries.
	if row.Provider == "codex" {
		lines = m.appendField(lines, "Tokens", formatTokens(row.Tokens), width)
	}
	lines = m.appendField(lines, "Started", formatTime(row.Started), width)
	lines = m.appendField(lines, "Blocked since", formatTime(row.Blocked), width)
	lines = m.appendField(lines, "Retry due", formatTime(row.Due), width)
	if row.Attempt > 0 {
		lines = m.appendField(lines, "Attempt", fmt.Sprint(row.Attempt), width)
	}
	lines = m.appendField(lines, "Last event", row.LastEvent, width)
	lines = m.appendField(lines, "Observed at", formatTime(row.LastEventAt), width)
	lines = m.appendField(lines, "Reason", row.Reason, width)
	if m.detailErr != nil {
		lines = m.appendField(lines, "Detail", m.detailErr.Error(), width)
	}
	return lines
}

func (m model) agentLines(width int) []string {
	lines := []string{m.sectionHeading("AGENT AVAILABILITY", width), ""}
	for _, provider := range providers {
		if !m.showStrip() && len(m.assets.sprites[provider.key].still) > 0 {
			lines = append(lines, m.providerCard(provider, width, artHeight)...)
		} else {
			status, _ := m.providerStatus(provider.key)
			lines = append(lines, m.paint("  "+provider.name, m.palette.accent, nil, true))
			lines = m.appendField(lines, "Observed", status, width)
		}
		for _, row := range m.tickets {
			if row.Provider == provider.key {
				reference := row.ID + "  " + row.Status
				if row.Model != "" {
					reference += "  " + strings.TrimSpace(row.Model+" "+row.Effort)
				}
				lines = m.appendField(lines, "Ticket", reference, width)
			}
		}
		quota := "Unreported"
		if provider.key == "codex" {
			lines = m.appendField(lines, "Tokens", formatTokens(m.snapshot.CodexTotals), width)
			quota = codexLimits(m.snapshot.RateLimits)
		}
		lines = m.appendField(lines, "Quota", quota, width)
		lines = append(lines, "")
	}
	return lines
}

func (m model) timelineLines(width int) []string {
	row, found := m.selectedTicket()
	if !found {
		return []string{m.sectionHeading("TIMELINE", width), "  Select a ticket in the queue"}
	}
	lines := []string{m.sectionHeading(clean(row.ID)+"  TIMELINE", width), ""}
	if m.detailErr != nil {
		return m.appendField(lines, "Detail", m.detailErr.Error(), width)
	}
	if len(m.detail.Events) == 0 {
		if row.LastEvent == "" {
			return append(lines, "  No events reported for this ticket")
		}
		return m.appendField(lines, formatTime(row.LastEventAt), row.LastEvent, width)
	}
	for _, event := range m.detail.Events {
		label := formatTime(event.At)
		if providerKey(event.Provider) != "" {
			label += "  " + providerName(event.Provider)
		}
		lines = m.appendField(lines, label, event.Type, width)
		lines = m.appendField(lines, "", event.Message, width)
	}
	return lines
}

func (m model) appendField(lines []string, label, value string, width int) []string {
	value = clean(value)
	if value == "" {
		return lines
	}
	prefix := m.paint(clean(label), m.palette.muted, nil, false)
	if prefix != "" {
		value = prefix + "  " + value
	}
	for _, line := range strings.Split(ansi.Hardwrap(value, max(1, width-4), false), "\n") {
		lines = append(lines, "  "+line)
	}
	return lines
}

func (m model) footer() []string {
	hint := "  j/k Move  Enter Inspect  / Filter  ? Help  q Close"
	if m.page != queuePage || m.inspect {
		hint = "  j/k Scroll  Esc Queue  ? Help  q Close"
	}
	if m.width < 55 {
		hint = "  j/k Move  ? Help  q Close"
	}
	if m.width >= 74 {
		mode := "Read only  "
		hint = m.pad(hint, m.width-ansi.StringWidth(mode)) + mode
	}
	lines := []string{m.fill(hint, m.width, m.palette.rail, m.palette.text, false)}
	if m.showHelp {
		lines = append(lines,
			m.fill("  Tab Focus  1 Queue  2 Agents  3 Timeline", m.width, m.palette.rail, m.palette.text, false),
			m.fill("  Esc Back  PgUp/PgDn Scroll  / Filter", m.width, m.palette.rail, m.palette.text, false),
		)
	}
	return lines
}

func (m model) sectionHeading(value string, width int) string {
	return m.fill("  "+value, width, m.palette.rail, m.palette.text, true)
}

func (m model) glyph(unicode, ascii string) string {
	if m.opt.ascii {
		return ascii
	}
	return unicode
}

func (m model) clip(value string, width int) string {
	if width <= 0 {
		return ""
	}
	tail := m.glyph("…", "...")
	if ansi.StringWidth(tail) > width {
		tail = ""
	}
	return ansi.Truncate(value, width, tail)
}

func (m model) pad(value string, width int) string {
	line := m.clip(value, width)
	return line + strings.Repeat(" ", max(0, width-ansi.StringWidth(line)))
}

func (m model) fill(value string, width int, background, foreground color.Color, bold bool) string {
	return m.paint(m.pad(value, width), foreground, background, bold)
}

func (m model) paint(value string, foreground, background color.Color, bold bool) string {
	if m.opt.monochrome {
		return value
	}
	style := lipgloss.NewStyle().Bold(bold)
	if foreground != nil {
		style = style.Foreground(foreground)
	}
	if background != nil {
		style = style.Background(background)
	}
	return style.Render(value)
}

func fit(lines []string, height, offset int) []string {
	offset = max(0, min(offset, len(lines)-height))
	window := make([]string, height)
	copy(window, lines[offset:])
	return window
}

func clean(value string) string {
	stripped := ansi.Strip(value)
	stripped = strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return ' '
		}
		if unicode.IsControl(r) || unicode.In(r, unicode.Cf) {
			return -1
		}
		return r
	}, stripped)
	if len(stripped) > 1000 {
		stripped = strings.ToValidUTF8(stripped[:1000], "") + "..."
	}
	return strings.TrimSpace(stripped)
}

func formatTime(value time.Time) string {
	if value.IsZero() {
		return ""
	}
	return value.Local().Format("15:04:05")
}

func formatTokens(usage *tokenUsage) string {
	if usage == nil {
		return ""
	}
	var fields []string
	if usage.Total != nil {
		fields = append(fields, fmt.Sprintf("%d total", *usage.Total))
	}
	if usage.Input != nil {
		fields = append(fields, fmt.Sprintf("%d in", *usage.Input))
	}
	if usage.Output != nil {
		fields = append(fields, fmt.Sprintf("%d out", *usage.Output))
	}
	return strings.Join(fields, "  ")
}

func codexLimits(raw json.RawMessage) string {
	type bucket struct {
		Remaining *float64 `json:"remaining"`
		Limit     *float64 `json:"limit"`
		Percent   *float64 `json:"usedPercent"`
		PercentV1 *float64 `json:"used_percent"`
	}
	var values struct {
		Primary   bucket `json:"primary"`
		Secondary bucket `json:"secondary"`
	}
	if json.Unmarshal(raw, &values) != nil {
		return "Unreported"
	}
	var observations []string
	for index, value := range []bucket{values.Primary, values.Secondary} {
		name := []string{"primary", "secondary"}[index]
		percentage := value.Percent
		if percentage == nil {
			percentage = value.PercentV1
		}
		switch {
		case value.Remaining != nil && value.Limit != nil:
			observations = append(observations, fmt.Sprintf("%s %g/%g remaining", name, *value.Remaining, *value.Limit))
		case percentage != nil:
			observations = append(observations, fmt.Sprintf("%s %g%% used", name, *percentage))
		}
	}
	if len(observations) == 0 {
		return "Unreported"
	}
	return strings.Join(observations, "  ")
}

package main

import (
	"context"
	"errors"
	"image"
	"image/color"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestMotionUsesCurrentRunsAndRestsOnError(t *testing.T) {
	m := newModel(context.Background(), nil, options{})
	m.width, m.height = 110, 30
	frame := func(label string) []string {
		rows := make([]string, artHeight)
		rows[0] = label
		return rows
	}
	art := providerArtwork{
		still: frame("still"),
		rest:  [][]string{frame("rest 1"), frame("rest 2")},
		work:  [][]string{frame("work 1"), frame("work 2")},
	}
	m.assets.sprites = map[string]providerArtwork{"codex": art, "gemini": art}
	now := time.Now()

	poll := func(at time.Time, state snapshot) {
		next, _ := m.Update(pollResult{receivedAt: at, snapshot: state})
		m = next.(model)
	}
	tick := func(at time.Time) {
		next, command := m.Update(spriteTick(at))
		if command == nil {
			t.Fatal("visible motion did not schedule its next tick")
		}
		m = next.(model)
	}

	m.updateMotions(now, nil)
	if m.scheduleSpriteTick() == nil || m.sprite("gemini")[0] != "rest 1" {
		t.Fatal("startup should animate the rest pose while connecting")
	}
	startupError := errors.New("offline")
	m.receivePoll(pollResult{receivedAt: now.Add(time.Millisecond), err: startupError})
	tick(now.Add(restFrameInterval))
	if m.sprite("gemini")[0] != "rest 2" || !strings.Contains(m.render(), "Status unknown") {
		t.Fatal("the first failed poll should keep the rest loop and show unknown status")
	}
	now = now.Add(2 * restFrameInterval)
	m.updateMotions(now, nil)
	restStarted := m.motions["codex"].since
	work := snapshot{Running: []ticket{{ID: "ISSUE-1", Provider: "gemini"}}}
	poll(now, work)
	if m.motions["gemini"].kind != motionWork || m.motions["codex"].kind != motionRest || !m.spriteQueued {
		t.Fatal("the initial snapshot did not start working and resting loops together")
	}
	if m.scheduleSpriteTick() != nil {
		t.Fatal("more than one animation timer was queued")
	}

	tick(now.Add(5 * workFrameInterval))
	poll(now.Add(5*workFrameInterval), work)
	if m.sprite("gemini")[0] != "work 2" || m.sprite("codex")[0] != "rest 2" {
		t.Fatal("both loops should advance through a repeated poll")
	}
	tick(now.Add(2 * restFrameInterval))
	if m.sprite("gemini")[0] != "work 1" || m.sprite("codex")[0] != "rest 1" {
		t.Fatal("both sequences should wrap continuously")
	}

	nextAt := now.Add(3 * restFrameInterval)
	poll(nextAt, snapshot{Retrying: work.Running})
	if m.sprite("gemini")[0] != "rest 1" || !m.motions["codex"].since.Equal(restStarted) {
		t.Fatal("retrying should select rest without resetting other providers")
	}
	tick(nextAt.Add(restFrameInterval))
	if m.sprite("gemini")[0] != "rest 2" {
		t.Fatal("rest loop did not continue on a retry")
	}

	activeAt := nextAt.Add(2 * restFrameInterval)
	poll(activeAt, work)
	disconnectedAt := activeAt.Add(workFrameInterval)
	m.receivePoll(pollResult{receivedAt: disconnectedAt, err: startupError})
	if m.sprite("gemini")[0] != "rest 1" || !strings.Contains(m.render(), "Stale snapshot") ||
		!strings.Contains(m.render(), "Status unknown") {
		t.Fatal("disconnect should select rest and expose stale status immediately")
	}
	m.receivePoll(pollResult{receivedAt: disconnectedAt.Add(time.Millisecond), err: startupError})
	tick(disconnectedAt.Add(restFrameInterval))
	if m.sprite("gemini")[0] != "rest 2" {
		t.Fatal("rest motion should continue through repeated failures")
	}
	poll(disconnectedAt.Add(2*restFrameInterval), work)
	if m.motions["gemini"].kind != motionWork || !m.spriteQueued {
		t.Fatal("the current work loop did not resume after reconnect")
	}

	m.opt.noMotion = true
	m.receivePoll(pollResult{receivedAt: disconnectedAt.Add(3 * restFrameInterval), err: startupError})
	poll(disconnectedAt.Add(4*restFrameInterval), work)
	if len(m.motions) != 0 {
		t.Fatal("motion ran after being disabled")
	}
}

func TestMotionTimerWaitsForVisibleCards(t *testing.T) {
	m := newModel(context.Background(), nil, options{})
	m.assets.sprites = map[string]providerArtwork{"codex": {rest: [][]string{{"rest"}}}}
	m.width, m.height = 60, 20
	m.receivePoll(pollResult{receivedAt: time.Now()})
	if m.scheduleSpriteTick() != nil {
		t.Fatal("the compact queue has no visible cards")
	}
	next, cmd := m.Update(tea.KeyPressMsg{Code: '2'})
	m = next.(model)
	if cmd == nil || !m.spriteQueued {
		t.Fatal("opening the Agents page did not schedule visible motion")
	}
	next, _ = m.Update(tea.KeyPressMsg{Code: '1'})
	m = next.(model)
	_, cmd = m.Update(spriteTick(time.Now()))
	if cmd != nil {
		t.Fatal("the hidden animation kept scheduling frames")
	}
}

func TestSelectionSurvivesPollAndIgnoresLateDetail(t *testing.T) {
	m := newModel(context.Background(), nil, options{})
	now := time.Now()
	m.receivePoll(pollResult{receivedAt: now, snapshot: snapshot{
		Blocked: []ticket{{ID: "ISSUE-2"}}, Running: []ticket{{ID: "ISSUE-1"}},
	}})
	if m.selected != "ISSUE-2" {
		t.Fatal("the blocked ticket was not prioritized")
	}
	m.move(1)
	if m.selected != "ISSUE-1" {
		t.Fatal("keyboard navigation did not move selection")
	}
	m.receivePoll(pollResult{
		receivedAt: now,
		snapshot:   snapshot{Blocked: []ticket{{ID: "ISSUE-0"}, {ID: "ISSUE-2"}}, Running: []ticket{{ID: "ISSUE-1"}}},
		detailID:   "ISSUE-2",
		detail:     ticketDetail{ID: "ISSUE-2", Events: []event{{Type: "different ticket"}}},
	})
	if m.selected != "ISSUE-1" || len(m.detail.Events) != 0 {
		t.Fatal("new snapshot changed selection or applied a late result")
	}
}

func TestMouseNavigationUsesVisibleTabsAndQueueRows(t *testing.T) {
	m := newModel(context.Background(), nil, options{})
	m.width, m.height = 120, 26
	m.receivePoll(pollResult{receivedAt: time.Now(), snapshot: snapshot{
		Running: []ticket{{ID: "SYM-1"}, {ID: "SYM-2"}, {ID: "SYM-3"}},
	}})

	update := func(msg tea.Msg) {
		next, _ := m.Update(msg)
		m = next.(model)
	}
	update(tea.MouseClickMsg{X: m.navStart(m.navLabels()) + len("1 Queue  "), Button: tea.MouseLeft})
	if m.page != agentsPage || m.View().MouseMode != tea.MouseModeCellMotion {
		t.Fatal("the Agents tab did not respond to a click")
	}
	update(tea.MouseClickMsg{X: m.navStart(m.navLabels()), Button: tea.MouseLeft})
	update(tea.MouseClickMsg{X: 2, Y: m.bodyTop() + 2, Button: tea.MouseLeft})
	if m.page != queuePage || m.selected != "SYM-2" {
		t.Fatal("clicking the second queue row did not select it")
	}
	update(tea.MouseWheelMsg{X: 2, Y: m.bodyTop() + 2, Button: tea.MouseWheelDown})
	if m.selected != "SYM-3" {
		t.Fatal("scrolling over the queue did not move selection")
	}
	update(tea.MouseClickMsg{X: m.queueWidth() + 1, Y: m.bodyTop() + 1, Button: tea.MouseLeft})
	if m.selected != "SYM-3" {
		t.Fatal("clicking the inspector changed queue selection")
	}
	m.width = 57
	update(tea.MouseClickMsg{X: 2, Y: m.bodyTop() + 1, Button: tea.MouseLeft})
	if m.selected != "SYM-1" || !m.inspect {
		t.Fatal("clicking a compact queue row did not open the inspector")
	}
}

func TestTerminalSafeStringsAndResponsiveViews(t *testing.T) {
	raw := "Before\x1b]52;c;ignored\x07\x1b[31m\x9b32m\u202e\u2066\x00\r\nAfter"
	safe := clean(raw)
	if strings.ContainsAny(safe, "\x1b\x07\x9b\u202e\u2066\x00\r\n") ||
		strings.Contains(safe, "ignored") || !strings.Contains(safe, "After") {
		t.Fatalf("unsafe sanitized text %q", safe)
	}

	m := newModel(context.Background(), nil, options{ascii: true, monochrome: true})
	now := time.Now()
	m.receivePoll(pollResult{receivedAt: now, snapshot: snapshot{
		GeneratedAt: now,
		Running:     []ticket{{ID: "ISSUE-1", Provider: "gemini", Title: strings.Repeat("開発", 200), LastEvent: raw}},
	}})
	m.detail = ticketDetail{ID: "ISSUE-1", Events: []event{{Type: raw, Message: raw + strings.Repeat("開発", 200)}}}
	for _, width := range []int{40, 60, 80, 120} {
		for _, height := range []int{12, 24, 32} {
			m.width, m.height = width, height
			for _, current := range []page{queuePage, agentsPage, timelinePage} {
				m.page = current
				for _, inspection := range []bool{false, true} {
					m.inspect = inspection
					lines := strings.Split(m.render(), "\n")
					if len(lines) > height {
						t.Fatalf("render has %d lines at %dx%d", len(lines), width, height)
					}
					for _, line := range lines {
						if ansi.StringWidth(line) > width {
							t.Fatalf("render overflow at %dx%d, width %d: %q", width, height, ansi.StringWidth(line), line)
						}
						if strings.ContainsRune(line, '\x1b') {
							t.Fatalf("ANSI sequence in monochrome render: %q", line)
						}
					}
				}
			}
		}
	}
	next, _ := m.Update(tea.KeyPressMsg{Code: '1'})
	if next.(model).page != queuePage {
		t.Fatal("could not navigate to the queue")
	}
}

func TestTransparentAssetKeepsBoundedTerminalDimensions(t *testing.T) {
	image := image.NewRGBA(image.Rect(0, 0, 43, 53))
	image.Set(10, 10, color.RGBA{R: 213, B: 93, A: 255})
	image.Set(40, 50, color.RGBA{G: 140, A: 255})
	if bounds := visibleBounds(image); bounds.Dx() != 31 || bounds.Dy() != 41 {
		t.Fatalf("unexpected alpha bounds %v", bounds)
	}
	for _, line := range renderArt(spriteFrame(image, visibleBounds(image), 0, 0)) {
		if ansi.StringWidth(line) != artWidth {
			t.Fatalf("art cell width = %d", ansi.StringWidth(line))
		}
	}
}

func TestInspectorAttributesLegacyCountersOnlyToCodex(t *testing.T) {
	m := newModel(context.Background(), nil, options{ascii: true, monochrome: true})
	m.selected = "TASK-1"
	total := int64(5)
	for _, provider := range []string{"", "claude", "gemini", "codex"} {
		m.tickets = []ticket{{ID: m.selected, Provider: provider, Tokens: &tokenUsage{Total: &total}}}
		inspector := strings.Join(m.issueLines(80), "\n")
		if strings.Contains(inspector, "5 total") != (provider == "codex") {
			t.Fatalf("unexpected token attribution for %q: %q", provider, inspector)
		}
	}
}

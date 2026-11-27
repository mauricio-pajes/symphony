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

func TestMotionUsesNewActivityAndClearsOnError(t *testing.T) {
	now := time.Now()
	sample := func(at time.Time, provider string) pollResult {
		return pollResult{receivedAt: at, snapshot: snapshot{
			GeneratedAt: at,
			Running:     []ticket{{ID: "ISSUE-1", Provider: provider, LastEventAt: at}},
		}}
	}
	m := newModel(context.Background(), nil, options{})
	if m.receivePoll(sample(now, "gemini")) != nil || len(m.pulse) != 0 {
		t.Fatal("initial state animated")
	}
	if m.receivePoll(sample(now, "gemini")) != nil || len(m.pulse) != 0 {
		t.Fatal("repeated observation animated")
	}
	if m.receivePoll(sample(now.Add(time.Second), "gemini")) == nil || !m.pulse["gemini"] {
		t.Fatal("new observed event did not animate its provider")
	}
	animation := m
	for range spriteMotion {
		next, _ := animation.Update(spriteTick(m.pulseSeq))
		animation = next.(model)
	}
	if len(animation.pulse) != 0 {
		t.Fatal("motion did not stop at the end of its sequence")
	}
	m.receivePoll(pollResult{err: errors.New("offline")})
	if len(m.pulse) != 0 || !strings.Contains(m.render(), "Stale snapshot") {
		t.Fatal("disconnect did not clear motion and expose stale status immediately")
	}
	if m.receivePoll(sample(now.Add(3*time.Second), "codex")) != nil || len(m.pulse) != 0 {
		t.Fatal("reconnect animated unobserved history")
	}
	if m.receivePoll(sample(now.Add(4*time.Second), "")) != nil || len(m.pulse) != 0 {
		t.Fatal("unattributed activity animated")
	}

	reduced := newModel(context.Background(), nil, options{noMotion: true})
	reduced.receivePoll(sample(now, "gemini"))
	if reduced.receivePoll(sample(now.Add(time.Second), "gemini")) != nil {
		t.Fatal("motion ran after being disabled")
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
	for _, line := range renderArt(spriteFrame(image, visibleBounds(image), 0)) {
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

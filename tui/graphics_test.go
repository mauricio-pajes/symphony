package main

import (
	"context"
	"image"
	"image/color"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestNativeArtOnlyForKnownVirtualPlacementTerminals(t *testing.T) {
	for _, test := range []struct {
		env  map[string]string
		want bool
	}{
		{map[string]string{"TERM": "xterm-ghostty"}, true},
		{map[string]string{"TERM": "xterm-kitty"}, true},
		{map[string]string{"TERM": "xterm-256color"}, false},
		{map[string]string{"TERM": "xterm-ghostty", "TMUX": "active"}, false},
		{map[string]string{"TERM": "xterm-kitty", "ZELLIJ_SESSION_NAME": "active"}, false},
	} {
		if supportsNativeArt(func(key string) string { return test.env[key] }) != test.want {
			t.Errorf("unexpected graphics support for %v", test.env)
		}
	}
}

func TestGraphicsFollowTheAlternateScreen(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "terminal")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	out := &artworkOutput{File: file, art: artwork{load: "<load>", clear: "<clear>"}}
	writes := []string{"main", ansi.SetModeAltScreenSaveCursor + "first", "second", ansi.ResetModeAltScreenSaveCursor, "main"}
	for _, write := range writes {
		n, err := io.WriteString(out, write)
		if err != nil || n != len(write) {
			t.Fatalf("write returned %d, %v", n, err)
		}
	}
	got, err := os.ReadFile(file.Name())
	want := "main" + ansi.SetModeAltScreenSaveCursor + "<load>firstsecond<clear>" + ansi.ResetModeAltScreenSaveCursor + "main"
	if err != nil || string(got) != want {
		t.Fatalf("unexpected screen and artwork order %q (error %v)", got, err)
	}
}

func TestProviderArtMovesInsideTheSameFrame(t *testing.T) {
	dir := t.TempDir()
	source := image.NewNRGBA(image.Rect(0, 0, 80, 60))
	for y := 12; y < 48; y++ {
		for x := 10; x < 70; x++ {
			source.SetNRGBA(x, y, color.NRGBA{R: 221, G: 123, B: 80, A: 255})
		}
	}
	for _, provider := range providers {
		file, err := os.Create(filepath.Join(dir, provider.image))
		if err != nil {
			t.Fatal(err)
		}
		if err := png.Encode(file, source); err != nil {
			t.Fatal(err)
		}
		if err := file.Close(); err != nil {
			t.Fatal(err)
		}
	}

	for _, native := range []bool{false, true} {
		m := newModel(context.Background(), nil, options{assets: dir, nativeArt: native})
		for _, provider := range providers {
			still := m.assets.sprites[provider.key][0]
			m.pulse = map[string]bool{provider.key: true}
			m.pulseStep = 1
			frame := m.sprite(provider.key)
			if len(frame) != artHeight || slices.Equal(frame, still) {
				t.Fatalf("%s artwork did not move (native=%t)", provider.key, native)
			}
			for _, row := range frame {
				if ansi.StringWidth(row) != artWidth {
					t.Fatalf("art row no longer occupies %d cells", artWidth)
				}
			}
		}
		for _, width := range []int{40, 80, 108, 132} {
			m.width, m.height = width, 24
			m.page = agentsPage
			for _, line := range strings.Split(m.render(), "\n") {
				if ansi.StringWidth(line) > width {
					t.Fatalf("mascot layout overflows %d columns (native=%t)", width, native)
				}
			}
		}
		if native && (strings.Count(m.assets.load, "U=1") != 9 ||
			strings.Count(m.assets.clear, "d=I,") != 9 || strings.Contains(m.assets.clear, "d=A")) {
			t.Fatal("native graphics did not scope uploads and cleanup to their own frames")
		}
	}
}

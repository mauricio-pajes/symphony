package main

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"image"
	"image/png"
	"math/rand/v2"
	"os"
	"strings"
	"sync"

	"github.com/charmbracelet/x/ansi"
)

const kittyChunkSize = 4096

// The first 14 row and column coordinates in the Kitty graphics protocol.
var kittyCoordinates = [...]rune{
	0x0305, 0x030d, 0x030e, 0x0310, 0x0312, 0x033d, 0x033e,
	0x033f, 0x0346, 0x034a, 0x034b, 0x034c, 0x0350, 0x0351,
}

func supportsNativeArt(env func(string) string) bool {
	for _, name := range []string{"TMUX", "TMUX_PANE", "ZELLIJ", "ZELLIJ_SESSION_NAME", "STY", "HERDR"} {
		if env(name) != "" {
			return false
		}
	}
	// Virtual placements must be supported, not just Kitty image uploads.
	switch env("TERM") {
	case "xterm-ghostty", "xterm-kitty":
		return true
	default:
		return false
	}
}

// Use the 24 bits that the placeholder can carry via its foreground color.
// Leave space for all frames without wrapping or touching reserved ID zero.
func firstImageID() uint32 {
	return 1 + rand.Uint32N((1<<24)-1-uint32(len(providers)*(1+3*maxStripFrames)))
}

func kittyImage(img image.Image, id uint32) (string, error) {
	var data bytes.Buffer
	if err := png.Encode(&data, img); err != nil {
		return "", err
	}
	encoded := base64.StdEncoding.EncodeToString(data.Bytes())
	var output strings.Builder
	for offset := 0; offset < len(encoded); offset += kittyChunkSize {
		end := min(offset+kittyChunkSize, len(encoded))
		more := 0
		if end < len(encoded) {
			more = 1
		}
		if offset == 0 {
			fmt.Fprintf(&output, "\x1b_Ga=T,f=100,t=d,q=2,U=1,i=%d,c=%d,r=%d,m=%d;", id, artWidth, artHeight, more)
		} else {
			fmt.Fprintf(&output, "\x1b_Gm=%d;", more)
		}
		output.WriteString(encoded[offset:end])
		output.WriteString("\x1b\\")
	}
	return output.String(), nil
}

func kittyCells(id uint32) []string {
	setForeground := fmt.Sprintf("\x1b[38;2;%d;%d;%dm", byte(id>>16), byte(id>>8), byte(id))
	rows := make([]string, artHeight)
	for y := range rows {
		var line strings.Builder
		line.WriteString(setForeground)
		for x := range artWidth {
			line.WriteRune('\U0010EEEE')
			line.WriteRune(kittyCoordinates[y])
			line.WriteRune(kittyCoordinates[x])
		}
		line.WriteString("\x1b[39m")
		rows[y] = line.String()
	}
	return rows
}

func kittyDelete(id uint32) string {
	return fmt.Sprintf("\x1b_Ga=d,d=I,i=%d,q=2;\x1b\\", id)
}

// Kitty placements belong to the current screen. Tie their lifetime to the
// renderer's actual screen switch, even when it buffers the initial paint.
type artworkOutput struct {
	*os.File
	art    artwork
	active bool
	mu     sync.Mutex
}

func (out *artworkOutput) WriteString(data string) (int, error) {
	return out.Write([]byte(data))
}

func (out *artworkOutput) Write(data []byte) (int, error) {
	out.mu.Lock()
	defer out.mu.Unlock()

	enter, leave := []byte(ansi.SetModeAltScreenSaveCursor), []byte(ansi.ResetModeAltScreenSaveCursor)
	var updated []byte
	switch {
	case !out.active && bytes.Contains(data, enter):
		updated = bytes.Replace(data, enter, []byte(ansi.SetModeAltScreenSaveCursor+out.art.load), 1)
		out.active = true
	case out.active && bytes.Contains(data, leave):
		updated = bytes.Replace(data, leave, []byte(out.art.clear+ansi.ResetModeAltScreenSaveCursor), 1)
		out.active = false
	default:
		return out.File.Write(data)
	}
	if _, err := out.File.Write(updated); err != nil {
		return 0, err
	}
	return len(data), nil
}

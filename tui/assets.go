package main

import (
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"

	"charm.land/lipgloss/v2"
)

const (
	artWidth      = 14
	artHeight     = 7
	spriteSize    = 224
	maxAssetBytes = 1 << 20
)

type providerInfo struct {
	key, name, abbreviation, image string
}

var providers = [...]providerInfo{
	{"codex", "Codex", "CX", "codex.png"},
	{"claude", "Claude Code", "CC", "claude.png"},
	{"gemini", "Antigravity", "AG", "antigravity.png"},
}

type artwork struct {
	sprites map[string][][]string
	load    string
	clear   string
}

func providerKey(key string) string {
	switch key {
	case "codex", "claude", "gemini":
		return key
	default:
		return ""
	}
}

func providerName(key string) string {
	for _, provider := range providers {
		if provider.key == key {
			return provider.name
		}
	}
	return "Unreported provider"
}

func providerAssets(opt options) artwork {
	result := artwork{sprites: make(map[string][][]string)}
	if opt.assets == "" || opt.monochrome {
		return result
	}

	id := firstImageID()
	var load, clear strings.Builder
	lifts := []int{0, 10, 20}
	if opt.noMotion {
		lifts = lifts[:1]
	}

	for _, provider := range providers {
		original := loadArt(filepath.Join(opt.assets, provider.image))
		if original == nil {
			continue
		}
		bounds := visibleBounds(original)
		if bounds.Empty() {
			continue
		}

		useNative := opt.nativeArt
		var frames [][]string
		var commands, deletes strings.Builder
		for _, lift := range lifts {
			frame := spriteFrame(original, bounds, lift)
			if useNative {
				command, err := kittyImage(frame, id)
				if err != nil {
					// Keep one representation for the whole sequence.
					useNative = false
					break
				}
				commands.WriteString(command)
				deletes.WriteString(kittyDelete(id))
				frames = append(frames, kittyCells(id))
				id++
			} else {
				frames = append(frames, renderArt(frame))
			}
		}
		if !useNative && opt.nativeArt {
			frames = frames[:0]
			for _, lift := range lifts {
				frames = append(frames, renderArt(spriteFrame(original, bounds, lift)))
			}
		}
		if useNative {
			load.WriteString(commands.String())
			clear.WriteString(deletes.String())
		}
		result.sprites[provider.key] = frames
	}
	result.load, result.clear = load.String(), clear.String()
	return result
}

func loadArt(path string) image.Image {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxAssetBytes {
		return nil
	}
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()
	config, err := png.DecodeConfig(file)
	if err != nil || config.Width > 1024 || config.Height > 1024 {
		return nil
	}
	if _, err := file.Seek(0, 0); err != nil {
		return nil
	}
	original, err := png.Decode(file)
	if err != nil {
		return nil
	}
	return original
}

func visibleBounds(img image.Image) image.Rectangle {
	bounds := img.Bounds()
	crop := image.Rectangle{}
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			_, _, _, alpha := img.At(x, y).RGBA()
			if alpha > 0x3000 {
				crop = crop.Union(image.Rect(x, y, x+1, y+1))
			}
		}
	}
	return crop
}

// Every pose occupies the same transparent square so motion never moves labels
// or alters the artwork's proportions. Nearest-neighbor keeps pixel edges crisp.
func spriteFrame(img image.Image, bounds image.Rectangle, lift int) *image.NRGBA {
	frame := image.NewNRGBA(image.Rect(0, 0, spriteSize, spriteSize))
	const span = 176
	largest := max(bounds.Dx(), bounds.Dy())
	width := max(1, bounds.Dx()*span/largest)
	height := max(1, bounds.Dy()*span/largest)
	left, top := (spriteSize-width)/2, (spriteSize-height)/2+6-lift
	for y := range height {
		sourceY := bounds.Min.Y + (2*y+1)*bounds.Dy()/(2*height)
		for x := range width {
			sourceX := bounds.Min.X + (2*x+1)*bounds.Dx()/(2*width)
			frame.Set(x+left, y+top, img.At(sourceX, sourceY))
		}
	}
	return frame
}

func renderArt(img *image.NRGBA) []string {
	pixel := func(x, y int) string {
		c := img.NRGBAAt((2*x+1)*spriteSize/(2*artWidth), (2*y+1)*spriteSize/(4*artHeight))
		if c.A < 64 {
			return ""
		}
		return rgb(c)
	}
	rows := make([]string, artHeight)
	for y := range rows {
		var line strings.Builder
		for x := range artWidth {
			line.WriteString(pixelCell(pixel(x, 2*y), pixel(x, 2*y+1)))
		}
		rows[y] = line.String()
	}
	return rows
}

func rgb(c color.NRGBA) string {
	return fmt.Sprintf("#%02x%02x%02x", c.R, c.G, c.B)
}

func pixelCell(top, bottom string) string {
	style := lipgloss.NewStyle()
	switch {
	case top != "" && bottom != "":
		return style.Foreground(lipgloss.Color(top)).Background(lipgloss.Color(bottom)).Render("▀")
	case top != "":
		return style.Foreground(lipgloss.Color(top)).Render("▀")
	case bottom != "":
		return style.Foreground(lipgloss.Color(bottom)).Render("▄")
	default:
		return " "
	}
}

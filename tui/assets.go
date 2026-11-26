package main

import (
	"fmt"
	"image"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"strings"

	"charm.land/lipgloss/v2"
)

const (
	artWidth      = 9
	artHeight     = 5
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

func providerAssets(opt options) map[string][]string {
	visuals := make(map[string][]string)
	if opt.assets == "" || opt.monochrome {
		return visuals
	}
	for _, provider := range providers {
		file := filepath.Join(opt.assets, provider.image)
		if art := loadArt(file); art != nil {
			visuals[provider.key] = art
		}
	}
	return visuals
}

func loadArt(path string) []string {
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
	bounds := visibleBounds(original)
	if bounds.Empty() {
		return nil
	}
	return renderArt(original, bounds)
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

func renderArt(img image.Image, bounds image.Rectangle) []string {
	scale := min(float64(artWidth)/float64(bounds.Dx()), float64(artHeight*2)/float64(bounds.Dy()))
	width := max(1, int(math.Round(float64(bounds.Dx())*scale)))
	height := max(1, int(math.Round(float64(bounds.Dy())*scale)))
	offsetX := (artWidth - width) / 2
	offsetY := (artHeight*2 - height) / 2

	pixel := func(x, y int) string {
		x, y = x-offsetX, y-offsetY
		if x < 0 || x >= width || y < 0 || y >= height {
			return ""
		}
		left := bounds.Min.X + x*bounds.Dx()/width
		top := bounds.Min.Y + y*bounds.Dy()/height
		right := bounds.Min.X + (x+1)*bounds.Dx()/width
		bottom := bounds.Min.Y + (y+1)*bounds.Dy()/height
		rect := image.Rect(left, top, max(left+1, right), max(top+1, bottom))
		return sampleColor(img, rect)
	}

	rows := make([]string, artHeight)
	for y := range artHeight {
		var line strings.Builder
		for x := range artWidth {
			line.WriteString(pixelCell(pixel(x, 2*y), pixel(x, 2*y+1)))
		}
		rows[y] = line.String()
	}
	return rows
}

func sampleColor(img image.Image, rect image.Rectangle) string {
	var r, g, b, alpha uint64
	for y := rect.Min.Y; y < rect.Max.Y; y++ {
		for x := rect.Min.X; x < rect.Max.X; x++ {
			red, green, blue, a := img.At(x, y).RGBA()
			r += uint64(red)
			g += uint64(green)
			b += uint64(blue)
			alpha += uint64(a)
		}
	}
	if alpha < uint64(rect.Dx()*rect.Dy())*0x3800 {
		return ""
	}
	return fmt.Sprintf("#%02x%02x%02x", r*255/alpha, g*255/alpha, b*255/alpha)
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

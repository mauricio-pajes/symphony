package main

import (
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"os"
	"path/filepath"
	"strings"

	"charm.land/lipgloss/v2"
)

const (
	artWidth       = 14
	artHeight      = 7
	spriteSize     = 224
	maxAssetBytes  = 1 << 20
	maxStripFrames = 8
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
	sprites map[string]providerArtwork
	load    string
	clear   string
}

type motion uint8

const (
	motionRest motion = iota
	motionWork
	motionReview
)

type providerArtwork struct {
	still              []string
	rest, work, review [][]string
}

func (art providerArtwork) frames(kind motion) [][]string {
	if kind == motionRest {
		return art.rest
	}
	if kind == motionReview && len(art.review) != 0 {
		return art.review
	}
	return art.work
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
	result := artwork{sprites: make(map[string]providerArtwork)}
	if opt.assets == "" || opt.monochrome {
		return result
	}

	id := firstImageID()
	var load, clear strings.Builder
	for _, provider := range providers {
		original := loadPNG(filepath.Join(opt.assets, provider.image), 1024, 1024)
		if original == nil {
			continue
		}
		bounds := visibleBounds(original)
		if bounds.Empty() {
			continue
		}

		still := spriteFrame(original, bounds, 0, 0)
		var rest, work, review []*image.NRGBA
		if !opt.noMotion {
			name := filepath.Join(opt.assets, strings.TrimSuffix(provider.image, ".png"))
			rest = loadStrip(name + "-rest.png")
			work = loadStrip(name + "-work.png")
			review = loadStrip(name + "-review.png")
			if len(rest) == 0 {
				breath := spriteFrame(original, bounds, 0, 5)
				rest = []*image.NRGBA{still, breath, spriteFrame(original, bounds, 0, 10), breath}
			}
			if len(work) == 0 {
				lift := spriteFrame(original, bounds, 10, 0)
				work = []*image.NRGBA{still, lift, spriteFrame(original, bounds, 24, 0), lift}
			}
		}

		art, commands, deletes := renderProviderArtwork(still, rest, work, review, opt.nativeArt, &id)
		load.WriteString(commands)
		clear.WriteString(deletes)
		result.sprites[provider.key] = art
	}
	result.load, result.clear = load.String(), clear.String()
	return result
}

func renderProviderArtwork(still *image.NRGBA, rest, work, review []*image.NRGBA, native bool, id *uint32) (providerArtwork, string, string) {
	var commands, deletes strings.Builder
	memo := make(map[*image.NRGBA][]string)
	render := func(frame *image.NRGBA) []string {
		if rows, exists := memo[frame]; exists {
			return rows
		}
		if native {
			if encoded, err := kittyImage(frame, *id); err == nil {
				commands.WriteString(encoded)
				deletes.WriteString(kittyDelete(*id))
				rows := kittyCells(*id)
				(*id)++
				memo[frame] = rows
				return rows
			}
		}
		rows := renderArt(frame)
		memo[frame] = rows
		return rows
	}
	renderEach := func(images []*image.NRGBA) [][]string {
		rows := make([][]string, 0, len(images))
		for _, frame := range images {
			rows = append(rows, render(frame))
		}
		return rows
	}
	art := providerArtwork{still: render(still), rest: renderEach(rest), work: renderEach(work), review: renderEach(review)}
	return art, commands.String(), deletes.String()
}

// All frames are square, ordered from left to right. Use common visible
// bounds across a strip so a change in pose does not recenter the character.
func loadStrip(path string) []*image.NRGBA {
	source := loadPNG(path, maxStripFrames*spriteSize, spriteSize)
	if source == nil {
		return nil
	}
	width, size := source.Bounds().Dx(), source.Bounds().Dy()
	if size == 0 || width%size != 0 || width/size < 2 || width/size > maxStripFrames {
		return nil
	}

	frames := make([]*image.NRGBA, width/size)
	var bounds image.Rectangle
	for i := range frames {
		frame := image.NewNRGBA(image.Rect(0, 0, size, size))
		draw.Draw(frame, frame.Bounds(), source, source.Bounds().Min.Add(image.Pt(i*size, 0)), draw.Src)
		frames[i] = frame
		bounds = bounds.Union(visibleBounds(frame))
	}
	if bounds.Empty() {
		return nil
	}
	for i, frame := range frames {
		frames[i] = spriteFrame(frame, bounds, 0, 0)
	}
	return frames
}

func loadPNG(path string, maxWidth, maxHeight int) image.Image {
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
	if err != nil || config.Width > maxWidth || config.Height > maxHeight {
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
func spriteFrame(img image.Image, bounds image.Rectangle, lift, squash int) *image.NRGBA {
	frame := image.NewNRGBA(image.Rect(0, 0, spriteSize, spriteSize))
	const span = 176
	largest := max(bounds.Dx(), bounds.Dy())
	width := max(1, bounds.Dx()*span/largest)
	height := max(1, bounds.Dy()*span/largest)
	left, top := (spriteSize-width)/2, (spriteSize-height)/2+6-lift
	// Keep the feet (or the base of a mark) planted during a breath.
	restHeight := max(1, height-squash)
	top += height - restHeight
	height = restHeight
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

package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
	"github.com/charmbracelet/x/term"
)

type options struct {
	assets      string
	theme       string
	ascii       bool
	noMotion    bool
	noAltScreen bool
	monochrome  bool
	nativeArt   bool
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "symphony-tui:", err)
		os.Exit(1)
	}
}

func run() error {
	var opt options
	address := flag.String("url", "http://127.0.0.1:4000", "local Symphony daemon URL")
	defaultAssets := ""
	if dir, err := os.UserConfigDir(); err == nil {
		defaultAssets = filepath.Join(dir, "symphony-tui", "assets")
	}
	flag.StringVar(&opt.assets, "assets", defaultAssets, "directory containing optional local provider PNGs")
	flag.StringVar(&opt.theme, "theme", "auto", "terminal theme (auto, dark or light)")
	flag.BoolVar(&opt.ascii, "ascii", false, "use ASCII markers and provider labels")
	flag.BoolVar(&opt.noMotion, "no-motion", false, "disable motion on new activity")
	flag.BoolVar(&opt.noAltScreen, "no-alt-screen", false, "render inline in the terminal")
	graphics := flag.String("graphics", "auto", "provider artwork renderer (auto or cells)")
	flag.Parse()

	switch opt.theme {
	case "auto", "dark", "light":
	default:
		return fmt.Errorf("unknown theme %q", opt.theme)
	}
	if *graphics != "auto" && *graphics != "cells" {
		return fmt.Errorf("unknown graphics mode %q", *graphics)
	}

	client, err := newDaemonClient(*address)
	if err != nil {
		return err
	}

	_, noColor := os.LookupEnv("NO_COLOR")
	opt.monochrome = opt.ascii || noColor || os.Getenv("TERM") == "dumb"
	opt.nativeArt = *graphics == "auto" && !opt.monochrome && !opt.noAltScreen &&
		term.IsTerminal(os.Stdout.Fd()) && supportsNativeArt(os.Getenv)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	model := newModel(ctx, client, opt)
	programOptions := []tea.ProgramOption{tea.WithContext(ctx)}
	if opt.monochrome {
		programOptions = append(programOptions, tea.WithColorProfile(colorprofile.NoTTY))
	} else if model.assets.load != "" {
		// Placeholder foreground colors encode exact image IDs.
		programOptions = append(programOptions,
			tea.WithColorProfile(colorprofile.TrueColor),
			tea.WithOutput(&artworkOutput{File: os.Stdout, art: model.assets}),
		)
	}
	_, err = tea.NewProgram(model, programOptions...).Run()
	if ctx.Err() != nil {
		return nil
	}
	return err
}

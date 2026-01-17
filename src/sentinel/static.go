// Package sentinel provides embedded static assets for the web UI.
package sentinel

import "embed"

// StaticFS contains the embedded static files (CSS, JS, images).
//
//go:embed static/*
var StaticFS embed.FS

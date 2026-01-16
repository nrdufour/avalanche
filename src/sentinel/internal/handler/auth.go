// Package handler contains HTTP handlers for Sentinel.
package handler

import (
	"net/http"

	"forge.internal/nemo/avalanche/src/sentinel/internal/auth"
	"forge.internal/nemo/avalanche/src/sentinel/templates/pages"
)

// AuthHandler handles authentication-related requests.
type AuthHandler struct {
	localAuth *auth.LocalAuthenticator
	sessions  *auth.SessionManager
}

// NewAuthHandler creates a new authentication handler.
func NewAuthHandler(localAuth *auth.LocalAuthenticator, sessions *auth.SessionManager) *AuthHandler {
	return &AuthHandler{
		localAuth: localAuth,
		sessions:  sessions,
	}
}

// LoginPage renders the login page.
func (h *AuthHandler) LoginPage(w http.ResponseWriter, r *http.Request) {
	// If already logged in, redirect to dashboard
	if h.sessions.IsAuthenticated(r) {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}

	component := pages.Login(pages.LoginParams{})
	component.Render(r.Context(), w)
}

// Login handles the login form submission.
func (h *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		h.renderLoginError(w, r, "Invalid form submission")
		return
	}

	username := r.FormValue("username")
	password := r.FormValue("password")

	if username == "" || password == "" {
		h.renderLoginError(w, r, "Username and password are required")
		return
	}

	user, err := h.localAuth.Authenticate(username, password)
	if err != nil {
		h.renderLoginError(w, r, "Invalid username or password")
		return
	}

	// Renew session token to prevent session fixation
	if err := h.sessions.RenewToken(r); err != nil {
		h.renderLoginError(w, r, "Session error")
		return
	}

	// Store user in session
	h.sessions.SetUser(r, user)

	// Redirect to dashboard
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// Logout handles user logout.
func (h *AuthHandler) Logout(w http.ResponseWriter, r *http.Request) {
	if err := h.sessions.ClearUser(r); err != nil {
		// Log error but continue with redirect
	}
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

// renderLoginError renders the login page with an error message.
func (h *AuthHandler) renderLoginError(w http.ResponseWriter, r *http.Request, errMsg string) {
	w.WriteHeader(http.StatusUnauthorized)
	component := pages.Login(pages.LoginParams{Error: errMsg})
	component.Render(r.Context(), w)
}

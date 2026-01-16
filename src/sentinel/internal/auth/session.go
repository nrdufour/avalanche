// Package auth handles authentication and session management for Sentinel.
package auth

import (
	"net/http"
	"time"

	"github.com/alexedwards/scs/v2"
)

const (
	// Session keys
	sessionKeyUserID   = "user_id"
	sessionKeyUsername = "username"
	sessionKeyRole     = "role"
)

// User represents an authenticated user in the session.
type User struct {
	ID       string
	Username string
	Role     string
}

// SessionManager wraps scs.SessionManager with helper methods.
type SessionManager struct {
	*scs.SessionManager
}

// NewSessionManager creates a new session manager with the given configuration.
func NewSessionManager(secret string, lifetime time.Duration, secure bool) *SessionManager {
	sm := scs.New()
	sm.Lifetime = lifetime
	sm.Cookie.Secure = secure
	sm.Cookie.HttpOnly = true
	sm.Cookie.SameSite = http.SameSiteStrictMode
	sm.Cookie.Name = "sentinel_session"

	return &SessionManager{SessionManager: sm}
}

// SetUser stores user information in the session.
func (sm *SessionManager) SetUser(r *http.Request, user *User) {
	sm.Put(r.Context(), sessionKeyUserID, user.ID)
	sm.Put(r.Context(), sessionKeyUsername, user.Username)
	sm.Put(r.Context(), sessionKeyRole, user.Role)
}

// GetUser retrieves user information from the session.
// Returns nil if no user is logged in.
func (sm *SessionManager) GetUser(r *http.Request) *User {
	userID := sm.GetString(r.Context(), sessionKeyUserID)
	if userID == "" {
		return nil
	}

	return &User{
		ID:       userID,
		Username: sm.GetString(r.Context(), sessionKeyUsername),
		Role:     sm.GetString(r.Context(), sessionKeyRole),
	}
}

// ClearUser removes user information from the session.
func (sm *SessionManager) ClearUser(r *http.Request) error {
	return sm.Destroy(r.Context())
}

// IsAuthenticated checks if a user is logged in.
func (sm *SessionManager) IsAuthenticated(r *http.Request) bool {
	return sm.GetUser(r) != nil
}

// HasRole checks if the logged-in user has the specified role.
func (sm *SessionManager) HasRole(r *http.Request, role string) bool {
	user := sm.GetUser(r)
	if user == nil {
		return false
	}
	return user.Role == role
}

// HasMinRole checks if the logged-in user has at least the specified role level.
// Role hierarchy: admin > operator > viewer
func (sm *SessionManager) HasMinRole(r *http.Request, minRole string) bool {
	user := sm.GetUser(r)
	if user == nil {
		return false
	}

	roleLevel := map[string]int{
		"viewer":   1,
		"operator": 2,
		"admin":    3,
	}

	userLevel, ok := roleLevel[user.Role]
	if !ok {
		return false
	}

	requiredLevel, ok := roleLevel[minRole]
	if !ok {
		return false
	}

	return userLevel >= requiredLevel
}

// RenewToken regenerates the session token (call after login for security).
func (sm *SessionManager) RenewToken(r *http.Request) error {
	return sm.SessionManager.RenewToken(r.Context())
}

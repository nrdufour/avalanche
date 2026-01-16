// Package middleware provides HTTP middleware for Sentinel.
package middleware

import (
	"net/http"

	"forge.internal/nemo/avalanche/src/sentinel/internal/auth"
)

// RequireAuth is middleware that requires authentication.
// Redirects to login page if not authenticated.
func RequireAuth(sm *auth.SessionManager) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !sm.IsAuthenticated(r) {
				http.Redirect(w, r, "/login", http.StatusSeeOther)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// RequireRole is middleware that requires a specific role.
// Returns 403 Forbidden if the user doesn't have the required role.
func RequireRole(sm *auth.SessionManager, role string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !sm.HasRole(r, role) {
				http.Error(w, "Forbidden", http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// RequireMinRole is middleware that requires at least a minimum role level.
// Role hierarchy: admin > operator > viewer
func RequireMinRole(sm *auth.SessionManager, minRole string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !sm.HasMinRole(r, minRole) {
				http.Error(w, "Forbidden", http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// APIRequireAuth is middleware for API endpoints that requires authentication.
// Returns 401 Unauthorized instead of redirecting.
func APIRequireAuth(sm *auth.SessionManager) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !sm.IsAuthenticated(r) {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

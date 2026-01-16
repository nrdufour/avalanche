package auth

import (
	"errors"
	"sync"

	"golang.org/x/crypto/bcrypt"

	"forge.internal/nemo/avalanche/src/sentinel/internal/config"
)

var (
	// ErrInvalidCredentials is returned when username or password is incorrect.
	ErrInvalidCredentials = errors.New("invalid username or password")
	// ErrUserNotFound is returned when the user does not exist.
	ErrUserNotFound = errors.New("user not found")
)

// LocalAuthenticator handles local username/password authentication.
type LocalAuthenticator struct {
	users map[string]*localUser
	mu    sync.RWMutex
}

// localUser represents a user in the local authenticator.
type localUser struct {
	Username     string
	PasswordHash string
	Role         string
}

// NewLocalAuthenticator creates a new local authenticator from configuration.
func NewLocalAuthenticator(cfg config.LocalAuthConfig) *LocalAuthenticator {
	auth := &LocalAuthenticator{
		users: make(map[string]*localUser),
	}

	for _, u := range cfg.Users {
		auth.users[u.Username] = &localUser{
			Username:     u.Username,
			PasswordHash: u.PasswordHash,
			Role:         u.Role,
		}
	}

	return auth
}

// Authenticate verifies username and password, returning the user if valid.
func (a *LocalAuthenticator) Authenticate(username, password string) (*User, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()

	user, ok := a.users[username]
	if !ok {
		// Still perform bcrypt comparison to prevent timing attacks
		bcrypt.CompareHashAndPassword([]byte("$2a$12$dummy"), []byte(password))
		return nil, ErrInvalidCredentials
	}

	err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password))
	if err != nil {
		return nil, ErrInvalidCredentials
	}

	return &User{
		ID:       username, // Using username as ID for local auth
		Username: username,
		Role:     user.Role,
	}, nil
}

// GetUser retrieves a user by username without verifying password.
func (a *LocalAuthenticator) GetUser(username string) (*User, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()

	user, ok := a.users[username]
	if !ok {
		return nil, ErrUserNotFound
	}

	return &User{
		ID:       username,
		Username: username,
		Role:     user.Role,
	}, nil
}

// UserExists checks if a user exists.
func (a *LocalAuthenticator) UserExists(username string) bool {
	a.mu.RLock()
	defer a.mu.RUnlock()
	_, ok := a.users[username]
	return ok
}

// HashPassword generates a bcrypt hash for a password.
// This is a utility function for generating hashes for config files.
func HashPassword(password string) (string, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	return string(hash), nil
}

// ValidatePassword checks if a password meets minimum requirements.
func ValidatePassword(password string) error {
	if len(password) < 8 {
		return errors.New("password must be at least 8 characters")
	}
	return nil
}

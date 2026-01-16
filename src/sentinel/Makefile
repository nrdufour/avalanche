.PHONY: all build run test clean generate templ css dev install-tools help

# Variables
BINARY_NAME=sentinel
VERSION?=$(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
BUILD_TIME=$(shell date -u '+%Y-%m-%d_%H:%M:%S')
LDFLAGS=-ldflags "-s -w -X main.Version=$(VERSION) -X main.BuildTime=$(BUILD_TIME)"

# Default target
all: generate build

# Install development tools
install-tools:
	@echo "Installing development tools..."
	go install github.com/a-h/templ/cmd/templ@latest
	@echo "Note: Install Tailwind CSS CLI separately (npm install -g tailwindcss)"

# Generate templ templates
templ:
	@echo "Generating templ templates..."
	templ generate

# Build Tailwind CSS
css:
	@echo "Building Tailwind CSS..."
	tailwindcss -i ./static/css/input.css -o ./static/css/styles.css --minify

# Generate all (templ + css)
generate: templ css

# Build the application
build: generate
	@echo "Building $(BINARY_NAME)..."
	go build $(LDFLAGS) -o $(BINARY_NAME) ./cmd/sentinel

# Build without generating (for quick rebuilds)
build-quick:
	@echo "Quick build $(BINARY_NAME)..."
	go build $(LDFLAGS) -o $(BINARY_NAME) ./cmd/sentinel

# Run the application
run: build
	./$(BINARY_NAME) -config config.yaml

# Run in development mode with auto-reload
dev:
	@echo "Starting development mode..."
	@echo "Run 'make templ' in another terminal for template changes"
	go run ./cmd/sentinel -config config.yaml

# Run tests
test:
	go test -v ./...

# Run tests with coverage
test-coverage:
	go test -v -coverprofile=coverage.out ./...
	go tool cover -html=coverage.out -o coverage.html

# Clean build artifacts
clean:
	@echo "Cleaning..."
	rm -f $(BINARY_NAME)
	rm -f coverage.out coverage.html
	find . -name '*_templ.go' -delete

# Format code
fmt:
	go fmt ./...
	templ fmt .

# Lint code
lint:
	@echo "Running linters..."
	go vet ./...
	@command -v staticcheck >/dev/null 2>&1 && staticcheck ./... || echo "staticcheck not installed"

# Generate a bcrypt password hash (usage: make hash-password PASSWORD=mysecret)
hash-password:
	@go run -mod=mod -exec "go run" ./cmd/hashpw/main.go "$(PASSWORD)"

# Tidy dependencies
tidy:
	go mod tidy

# Show help
help:
	@echo "Sentinel - Gateway Management Tool"
	@echo ""
	@echo "Available targets:"
	@echo "  all            - Generate and build (default)"
	@echo "  build          - Build the application"
	@echo "  build-quick    - Build without regenerating templates/css"
	@echo "  run            - Build and run the application"
	@echo "  dev            - Run in development mode"
	@echo "  test           - Run tests"
	@echo "  test-coverage  - Run tests with coverage report"
	@echo "  generate       - Generate templ templates and CSS"
	@echo "  templ          - Generate templ templates only"
	@echo "  css            - Build Tailwind CSS only"
	@echo "  clean          - Remove build artifacts"
	@echo "  fmt            - Format code"
	@echo "  lint           - Run linters"
	@echo "  tidy           - Tidy go modules"
	@echo "  install-tools  - Install development tools"
	@echo "  hash-password  - Generate bcrypt hash (PASSWORD=xxx)"
	@echo "  help           - Show this help"

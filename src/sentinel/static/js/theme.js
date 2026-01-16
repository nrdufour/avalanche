// Theme management for Sentinel
// Supports dark/light mode with system preference detection

(function() {
    'use strict';

    // Get the current theme from localStorage or system preference
    function getTheme() {
        const stored = localStorage.getItem('sentinel-theme');
        if (stored) {
            return stored;
        }
        // Check system preference
        if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
            return 'dark';
        }
        return 'light';
    }

    // Apply the theme to the document
    function applyTheme(theme) {
        if (theme === 'dark') {
            document.documentElement.classList.add('dark');
        } else {
            document.documentElement.classList.remove('dark');
        }
        updateIcons(theme);
    }

    // Update the theme toggle icons
    function updateIcons(theme) {
        const lightIcon = document.getElementById('theme-toggle-light-icon');
        const darkIcon = document.getElementById('theme-toggle-dark-icon');

        if (!lightIcon || !darkIcon) return;

        if (theme === 'dark') {
            // In dark mode, show the sun icon (to switch to light)
            lightIcon.classList.remove('hidden');
            darkIcon.classList.add('hidden');
        } else {
            // In light mode, show the moon icon (to switch to dark)
            lightIcon.classList.add('hidden');
            darkIcon.classList.remove('hidden');
        }
    }

    // Toggle the theme
    window.toggleTheme = function() {
        const current = getTheme();
        const next = current === 'dark' ? 'light' : 'dark';
        localStorage.setItem('sentinel-theme', next);
        applyTheme(next);
    };

    // Apply theme immediately to prevent flash
    applyTheme(getTheme());

    // Re-apply when DOM is ready (for icons)
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function() {
            updateIcons(getTheme());
        });
    } else {
        updateIcons(getTheme());
    }

    // Listen for system theme changes
    if (window.matchMedia) {
        window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function(e) {
            // Only auto-switch if no user preference is stored
            if (!localStorage.getItem('sentinel-theme')) {
                applyTheme(e.matches ? 'dark' : 'light');
            }
        });
    }
})();

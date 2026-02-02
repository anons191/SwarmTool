/**
 * Toast notification module
 * Displays success/error/info messages with auto-dismiss
 */

const Toast = {
  /**
   * Shows a success toast notification
   * @param {string} message - The message to display
   */
  success(message) {
    this._showToast(message, 'success');
  },

  /**
   * Shows an error toast notification
   * @param {string} message - The message to display
   */
  error(message) {
    this._showToast(message, 'error');
  },

  /**
   * Shows an info toast notification
   * @param {string} message - The message to display
   */
  info(message) {
    this._showToast(message, 'info');
  },

  /**
   * Internal method to create and display a toast
   * @private
   * @param {string} message - The message to display
   * @param {string} type - The toast type (success, error, info)
   */
  _showToast(message, type) {
    const container = document.getElementById('toast-container');
    if (!container) {
      console.error('Toast container not found');
      return;
    }

    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    toast.textContent = message;

    container.appendChild(toast);

    // Trigger animation by adding a small delay
    requestAnimationFrame(() => {
      toast.style.animation = 'slide-in 0.3s ease-out';
    });

    // Auto-remove after 3 seconds with fade out animation
    setTimeout(() => {
      toast.style.opacity = '0';
      toast.style.transform = 'translateX(100%)';

      // Remove from DOM after animation completes
      setTimeout(() => {
        if (toast.parentNode === container) {
          container.removeChild(toast);
        }
      }, 300);
    }, 3000);
  }
};

export default Toast;

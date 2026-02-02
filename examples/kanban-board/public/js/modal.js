// Modal classes for user interactions

class InputModal {
  static show(title, placeholder = '', defaultValue = '') {
    return new Promise((resolve) => {
      const modal = document.getElementById('input-modal');
      const titleEl = document.getElementById('input-modal-title');
      const input = document.getElementById('input-modal-input');
      const cancelBtn = document.getElementById('input-modal-cancel');
      const submitBtn = document.getElementById('input-modal-submit');

      // Set up modal
      titleEl.textContent = title;
      input.placeholder = placeholder;
      input.value = defaultValue;
      modal.classList.remove('hidden');
      input.focus();

      // Create AbortController for cleanup
      const controller = new AbortController();
      const signal = controller.signal;

      const hideModal = () => {
        modal.classList.add('hidden');
        input.value = '';
        controller.abort();
      };

      const handleCancel = () => {
        hideModal();
        resolve(null);
      };

      const handleSubmit = () => {
        const value = input.value.trim();
        hideModal();
        resolve(value || null);
      };

      // Event listeners with AbortController
      cancelBtn.addEventListener('click', handleCancel, { signal });
      submitBtn.addEventListener('click', handleSubmit, { signal });

      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
          handleSubmit();
        } else if (e.key === 'Escape') {
          handleCancel();
        }
      }, { signal });

      modal.addEventListener('click', (e) => {
        if (e.target === modal) {
          handleCancel();
        }
      }, { signal });
    });
  }
}

class ConfirmModal {
  static show(title, message) {
    return new Promise((resolve) => {
      const modal = document.getElementById('confirm-modal');
      const titleEl = document.getElementById('confirm-modal-title');
      const messageEl = document.getElementById('confirm-modal-message');
      const cancelBtn = document.getElementById('confirm-modal-cancel');
      const confirmBtn = document.getElementById('confirm-modal-confirm');

      // Set up modal
      titleEl.textContent = title;
      messageEl.textContent = message;
      modal.classList.remove('hidden');

      // Create AbortController for cleanup
      const controller = new AbortController();
      const signal = controller.signal;

      const hideModal = () => {
        modal.classList.add('hidden');
        controller.abort();
      };

      const handleCancel = () => {
        hideModal();
        resolve(false);
      };

      const handleConfirm = () => {
        hideModal();
        resolve(true);
      };

      // Event listeners with AbortController
      cancelBtn.addEventListener('click', handleCancel, { signal });
      confirmBtn.addEventListener('click', handleConfirm, { signal });

      document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
          handleCancel();
        }
      }, { signal });

      modal.addEventListener('click', (e) => {
        if (e.target === modal) {
          handleCancel();
        }
      }, { signal });
    });
  }
}

class CardModal {
  static show(card = null) {
    return new Promise((resolve) => {
      const modal = document.getElementById('card-modal');
      const titleInput = document.getElementById('card-modal-title');
      const descriptionInput = document.getElementById('card-modal-description');
      const dueDateInput = document.getElementById('card-modal-due-date');
      const labelsContainer = document.getElementById('card-modal-labels');
      const cancelBtn = document.getElementById('card-modal-cancel');
      const saveBtn = document.getElementById('card-modal-save');
      const deleteBtn = document.getElementById('card-modal-delete');
      const closeBtn = modal.querySelector('.modal-close-btn');

      // Create AbortController for cleanup
      const controller = new AbortController();
      const signal = controller.signal;

      // Set up modal based on mode (edit or create)
      if (card) {
        // Edit mode
        titleInput.value = card.title || '';
        descriptionInput.value = card.description || '';
        dueDateInput.value = card.due_date || '';

        // Clear all label selections first
        const labelOptions = labelsContainer.querySelectorAll('.label-option');
        labelOptions.forEach(option => {
          option.classList.remove('label-option-selected');
        });

        // Select labels from card
        if (card.labels && Array.isArray(card.labels)) {
          card.labels.forEach(color => {
            const labelOption = labelsContainer.querySelector(`[data-color="${color}"]`);
            if (labelOption) {
              labelOption.classList.add('label-option-selected');
            }
          });
        }

        deleteBtn.classList.remove('hidden');
      } else {
        // Create mode
        titleInput.value = '';
        descriptionInput.value = '';
        dueDateInput.value = '';

        // Clear all label selections
        const labelOptions = labelsContainer.querySelectorAll('.label-option');
        labelOptions.forEach(option => {
          option.classList.remove('label-option-selected');
        });

        deleteBtn.classList.add('hidden');
      }

      modal.classList.remove('hidden');
      titleInput.focus();

      const hideModal = () => {
        modal.classList.add('hidden');
        controller.abort();
      };

      const handleCancel = () => {
        hideModal();
        resolve(null);
      };

      const handleSave = () => {
        const title = titleInput.value.trim();

        // Validate title
        if (!title) {
          titleInput.focus();
          return;
        }

        const description = descriptionInput.value.trim();
        const due_date = dueDateInput.value;

        // Get selected labels
        const selectedLabels = Array.from(
          labelsContainer.querySelectorAll('.label-option-selected')
        ).map(option => option.getAttribute('data-color'));

        hideModal();
        resolve({
          title,
          description,
          due_date,
          labels: selectedLabels
        });
      };

      const handleDelete = () => {
        hideModal();
        resolve({ delete: true });
      };

      // Label picker toggle functionality
      const labelOptions = labelsContainer.querySelectorAll('.label-option');
      labelOptions.forEach(option => {
        option.addEventListener('click', () => {
          option.classList.toggle('label-option-selected');
        }, { signal });
      });

      // Event listeners with AbortController
      cancelBtn.addEventListener('click', handleCancel, { signal });
      saveBtn.addEventListener('click', handleSave, { signal });
      deleteBtn.addEventListener('click', handleDelete, { signal });

      if (closeBtn) {
        closeBtn.addEventListener('click', handleCancel, { signal });
      }

      document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
          handleCancel();
        }
      }, { signal });

      modal.addEventListener('click', (e) => {
        if (e.target === modal) {
          handleCancel();
        }
      }, { signal });
    });
  }
}

export { InputModal, ConfirmModal, CardModal };

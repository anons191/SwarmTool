import ColumnManager from './columnManager.js';

const DragDropManager = {
  // State
  draggedElement: null,
  draggedCardId: null,
  sourceColumnId: null,
  container: null,

  /**
   * Initialize drag and drop functionality
   * @param {HTMLElement} container - The container element to attach event listeners
   */
  init(container) {
    this.container = container;
    this.setupEventListeners();
  },

  /**
   * Set up event listeners using event delegation
   */
  setupEventListeners() {
    // Use event delegation on container
    this.container.addEventListener('dragstart', (e) => {
      if (e.target.closest('.card')) {
        this.handleDragStart(e);
      }
    });

    this.container.addEventListener('dragend', (e) => {
      if (e.target.closest('.card')) {
        this.handleDragEnd(e);
      }
    });

    this.container.addEventListener('dragover', (e) => {
      const columnCards = e.target.closest('.column-cards');
      if (columnCards) {
        this.handleDragOver(e);
      }
    });

    this.container.addEventListener('dragleave', (e) => {
      const columnCards = e.target.closest('.column-cards');
      if (columnCards) {
        this.handleDragLeave(e);
      }
    });

    this.container.addEventListener('drop', (e) => {
      const columnCards = e.target.closest('.column-cards');
      if (columnCards) {
        this.handleDrop(e);
      }
    });
  },

  /**
   * Handle drag start event
   * @param {DragEvent} e - The drag event
   */
  handleDragStart(e) {
    const card = e.target.closest('.card');
    if (!card) return;

    this.draggedElement = card;
    this.draggedCardId = card.dataset.cardId;

    const columnCards = card.closest('.column-cards');
    this.sourceColumnId = columnCards ? columnCards.dataset.columnId : null;

    card.classList.add('dragging');

    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', this.draggedCardId);
  },

  /**
   * Handle drag end event
   * @param {DragEvent} e - The drag event
   */
  handleDragEnd(e) {
    if (this.draggedElement) {
      this.draggedElement.classList.remove('dragging');
    }

    // Remove all drag-over classes
    const allColumnCards = this.container.querySelectorAll('.column-cards');
    allColumnCards.forEach(col => col.classList.remove('drag-over'));

    // Remove all drop indicators
    const indicators = this.container.querySelectorAll('.drop-indicator');
    indicators.forEach(indicator => indicator.remove());

    // Clear state
    this.draggedElement = null;
    this.draggedCardId = null;
    this.sourceColumnId = null;
  },

  /**
   * Handle drag over event
   * @param {DragEvent} e - The drag event
   */
  handleDragOver(e) {
    e.preventDefault();

    const columnCards = e.target.closest('.column-cards');
    if (!columnCards) return;

    columnCards.classList.add('drag-over');

    // Calculate and show drop position
    const mouseY = e.clientY;
    const position = this.getDropPosition(columnCards, mouseY);
    this.showDropIndicator(columnCards, position);

    e.dataTransfer.dropEffect = 'move';
  },

  /**
   * Handle drag leave event
   * @param {DragEvent} e - The drag event
   */
  handleDragLeave(e) {
    const columnCards = e.target.closest('.column-cards');
    if (!columnCards) return;

    // Only act if actually leaving the column-cards element (not its children)
    const rect = columnCards.getBoundingClientRect();
    const x = e.clientX;
    const y = e.clientY;

    if (
      x <= rect.left ||
      x >= rect.right ||
      y <= rect.top ||
      y >= rect.bottom
    ) {
      columnCards.classList.remove('drag-over');
      const indicator = columnCards.querySelector('.drop-indicator');
      if (indicator) {
        indicator.remove();
      }
    }
  },

  /**
   * Handle drop event
   * @param {DragEvent} e - The drag event
   */
  handleDrop(e) {
    e.preventDefault();

    const columnCards = e.target.closest('.column-cards');
    if (!columnCards) return;

    const targetColumnId = columnCards.dataset.columnId;
    const mouseY = e.clientY;
    const position = this.getDropPosition(columnCards, mouseY);

    // Remove visual feedback
    columnCards.classList.remove('drag-over');
    const indicator = columnCards.querySelector('.drop-indicator');
    if (indicator) {
      indicator.remove();
    }

    // Handle the drop based on same or different column
    if (this.sourceColumnId === targetColumnId) {
      // Same column - reorder cards
      const cards = Array.from(columnCards.querySelectorAll('.card:not(.dragging)'));
      const cardIds = [];

      // Build new order with dragged card inserted at position
      let insertedDragged = false;
      for (let i = 0; i < cards.length; i++) {
        if (i === position && !insertedDragged) {
          cardIds.push(this.draggedCardId);
          insertedDragged = true;
        }
        if (cards[i].dataset.cardId !== this.draggedCardId) {
          cardIds.push(cards[i].dataset.cardId);
        }
      }

      // If position is at the end, add dragged card at the end
      if (!insertedDragged) {
        cardIds.push(this.draggedCardId);
      }

      ColumnManager.reorderCards(targetColumnId, cardIds);
    } else {
      // Different column - move card
      ColumnManager.moveCard(this.draggedCardId, targetColumnId, position);
    }
  },

  /**
   * Get the drop position based on mouse Y coordinate
   * @param {HTMLElement} columnCardsElement - The column cards container
   * @param {number} mouseY - The mouse Y coordinate
   * @returns {number} The index position for insertion
   */
  getDropPosition(columnCardsElement, mouseY) {
    const cards = Array.from(
      columnCardsElement.querySelectorAll('.card:not(.dragging)')
    );

    if (cards.length === 0) {
      return 0;
    }

    for (let i = 0; i < cards.length; i++) {
      const card = cards[i];
      const rect = card.getBoundingClientRect();
      const cardMiddle = rect.top + rect.height / 2;

      if (mouseY < cardMiddle) {
        return i;
      }
    }

    // If we're past all cards, insert at the end
    return cards.length;
  },

  /**
   * Show drop indicator at the specified position
   * @param {HTMLElement} columnCardsElement - The column cards container
   * @param {number} position - The position index to show the indicator
   */
  showDropIndicator(columnCardsElement, position) {
    // Remove any existing indicator
    const existingIndicator = columnCardsElement.querySelector('.drop-indicator');
    if (existingIndicator) {
      existingIndicator.remove();
    }

    // Create new indicator
    const indicator = document.createElement('div');
    indicator.className = 'drop-indicator';

    // Get all cards (excluding dragging one)
    const cards = Array.from(
      columnCardsElement.querySelectorAll('.card:not(.dragging)')
    );

    if (cards.length === 0 || position >= cards.length) {
      // Insert at the end
      columnCardsElement.appendChild(indicator);
    } else {
      // Insert before the card at position
      columnCardsElement.insertBefore(indicator, cards[position]);
    }
  }
};

export default DragDropManager;

import { columnsApi, cardsApi } from './api.js';
import Toast from './toast.js';
import { InputModal, ConfirmModal, CardModal } from './modal.js';

const ColumnManager = {
  container: null,
  currentBoardId: null,
  columns: [],

  init(container) {
    this.container = container;
    this.setupEventDelegation();
  },

  setupEventDelegation() {
    this.container.addEventListener('click', (e) => {
      // Handle column delete button
      if (e.target.classList.contains('column-delete-btn')) {
        const columnId = e.target.dataset.columnId;
        this.deleteColumn(columnId);
      }

      // Handle add card button
      if (e.target.classList.contains('column-add-card-btn')) {
        const columnId = e.target.dataset.columnId;
        this.createCard(columnId);
      }

      // Handle card click
      if (e.target.closest('.card')) {
        const card = e.target.closest('.card');
        const cardId = card.dataset.cardId;
        this.editCard(cardId);
      }
    });
  },

  async loadColumns(boardId) {
    try {
      this.currentBoardId = boardId;

      // Fetch columns
      const columns = await columnsApi.getByBoard(boardId);

      // Fetch cards for each column
      this.columns = await Promise.all(
        columns.map(async (column) => {
          const cards = await cardsApi.getByColumn(column.id);
          return { ...column, cards };
        })
      );

      this.renderColumns();

      // Show/hide empty state
      const emptyState = document.getElementById('empty-state');
      if (this.columns.length === 0) {
        emptyState.classList.remove('hidden');
      } else {
        emptyState.classList.add('hidden');
      }
    } catch (error) {
      Toast.error('Failed to load columns');
      console.error('loadColumns failed:', error);
    }
  },

  renderColumns() {
    this.container.innerHTML = '';

    this.columns.forEach((column) => {
      const columnEl = document.createElement('div');
      columnEl.className = 'column';
      columnEl.dataset.columnId = column.id;

      const cardsHtml = column.cards.map(card => this.renderCard(card)).join('');

      columnEl.innerHTML = `
        <div class="column-header">
          <div>
            <span class="column-title">${this.escapeHtml(column.title)}</span>
            <span class="column-card-count">(${column.cards.length})</span>
          </div>
          <div class="column-actions">
            <button class="btn btn-icon column-delete-btn" data-column-id="${column.id}">🗑️</button>
          </div>
        </div>
        <div class="column-cards" data-column-id="${column.id}">
          ${cardsHtml}
        </div>
        <button class="btn btn-secondary column-add-card-btn" data-column-id="${column.id}">+ Add Card</button>
      `;

      this.container.appendChild(columnEl);
    });
  },

  renderCard(card) {
    const labelsHtml = card.labels && card.labels.length > 0
      ? `<div class="card-labels">
          ${card.labels.map(color => `<span class="card-label card-label-${color}"></span>`).join('')}
        </div>`
      : '';

    let dueDateHtml = '';
    if (card.due_date) {
      const dueDate = new Date(card.due_date);
      const today = new Date();
      today.setHours(0, 0, 0, 0);

      const dueDateOnly = new Date(dueDate);
      dueDateOnly.setHours(0, 0, 0, 0);

      const isOverdue = dueDateOnly < today;
      const diffDays = Math.ceil((dueDateOnly - today) / (1000 * 60 * 60 * 24));
      const isSoon = diffDays >= 0 && diffDays <= 2;

      const formattedDate = this.formatDate(dueDate);

      const classes = ['card-due-date'];
      if (isOverdue) classes.push('card-due-date-overdue');
      if (isSoon && !isOverdue) classes.push('card-due-date-soon');

      dueDateHtml = `<div class="${classes.join(' ')}">📅 ${formattedDate}</div>`;
    }

    return `
      <div class="card" data-card-id="${card.id}" draggable="true">
        <div class="card-title">${this.escapeHtml(card.title)}</div>
        ${labelsHtml}
        ${dueDateHtml}
      </div>
    `;
  },

  formatDate(date) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return `${months[date.getMonth()]} ${date.getDate()}`;
  },

  escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  },

  async createColumn(boardId) {
    try {
      const title = await InputModal.show('New Column', 'Enter column title');

      if (title === null) {
        return; // User cancelled
      }

      if (!title || title.trim() === '') {
        Toast.error('Column title cannot be empty');
        return;
      }

      const position = this.columns.length;

      await columnsApi.create(boardId, title, position);
      Toast.success('Column created');
      await this.loadColumns(boardId);
    } catch (error) {
      Toast.error('Failed to create column');
      console.error('createColumn failed:', error);
    }
  },

  async deleteColumn(columnId) {
    try {
      const column = this.columns.find(col => col.id === columnId);
      if (!column) return;

      const confirmed = await ConfirmModal.show(
        'Delete Column',
        `Delete "${column.title}" and all its cards?`
      );

      if (!confirmed) return;

      await columnsApi.delete(columnId);
      Toast.success('Column deleted');
      await this.loadColumns(this.currentBoardId);
    } catch (error) {
      Toast.error('Failed to delete column');
      console.error('deleteColumn failed:', error);
    }
  },

  async createCard(columnId) {
    try {
      const result = await CardModal.show();

      if (result === null) {
        return; // User cancelled
      }

      const column = this.columns.find(col => col.id === columnId);
      const position = column ? column.cards.length : 0;

      const cardData = {
        title: result.title,
        description: result.description,
        labels: result.labels,
        due_date: result.due_date,
        position
      };

      await cardsApi.create(columnId, cardData);
      Toast.success('Card created');
      await this.loadColumns(this.currentBoardId);
    } catch (error) {
      Toast.error('Failed to create card');
      console.error('createCard failed:', error);
    }
  },

  async editCard(cardId) {
    try {
      // Find card in columns data
      let card = null;
      for (const column of this.columns) {
        card = column.cards.find(c => c.id === cardId);
        if (card) break;
      }

      if (!card) return;

      const result = await CardModal.show(card);

      if (result === null) {
        return; // User cancelled
      }

      if (result.delete === true) {
        await this.deleteCard(cardId);
        return;
      }

      const updateData = {
        title: result.title,
        description: result.description,
        labels: result.labels,
        due_date: result.due_date
      };

      await cardsApi.update(cardId, updateData);
      Toast.success('Card updated');
      await this.loadColumns(this.currentBoardId);
    } catch (error) {
      Toast.error('Failed to update card');
      console.error('editCard failed:', error);
    }
  },

  async deleteCard(cardId) {
    try {
      await cardsApi.delete(cardId);
      Toast.success('Card deleted');
      await this.loadColumns(this.currentBoardId);
    } catch (error) {
      Toast.error('Failed to delete card');
      console.error('deleteCard failed:', error);
    }
  },

  async moveCard(cardId, targetColumnId, position) {
    try {
      await cardsApi.update(cardId, {
        column_id: targetColumnId,
        position
      });
      await this.loadColumns(this.currentBoardId);
    } catch (error) {
      Toast.error('Failed to move card');
      console.error('moveCard failed:', error);
    }
  },

  async reorderCards(columnId, cardIds) {
    try {
      await columnsApi.reorder(columnId, cardIds);
    } catch (error) {
      Toast.error('Failed to reorder cards');
      console.error('reorderCards failed:', error);
    }
  },

  getColumns() {
    return this.columns;
  }
};

export default ColumnManager;

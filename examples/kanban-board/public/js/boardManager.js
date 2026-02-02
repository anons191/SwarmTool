import { boardsApi } from './api.js';
import Toast from './toast.js';
import { InputModal, ConfirmModal } from './modal.js';

const BoardManager = {
  currentBoardId: null,
  boards: [],
  onBoardSelect: null,

  async init() {
    try {
      // Load all boards from API
      await this.loadBoards();

      // Set up new board button click handler
      const newBoardBtn = document.getElementById('new-board-btn');
      if (newBoardBtn) {
        newBoardBtn.addEventListener('click', () => this.createBoard());
      }

      // Auto-select first board if boards exist
      if (this.boards.length > 0) {
        this.selectBoard(this.boards[0].id);
      }
    } catch (err) {
      Toast.error('Failed to initialize board manager');
      console.error('BoardManager.init failed:', err);
    }
  },

  async loadBoards() {
    try {
      // Fetch boards from API
      this.boards = await boardsApi.getAll();

      // Render the board list
      this.renderBoardList();
    } catch (err) {
      Toast.error('Failed to load boards');
      console.error('BoardManager.loadBoards failed:', err);
      throw err;
    }
  },

  renderBoardList() {
    const container = document.getElementById('board-list');
    if (!container) return;

    // Clear container
    container.innerHTML = '';

    // Create board list items
    this.boards.forEach(board => {
      const boardItem = document.createElement('div');
      boardItem.className = 'board-list-item';
      boardItem.dataset.boardId = board.id;
      boardItem.textContent = board.name;

      // Add active class to current board
      if (board.id === this.currentBoardId) {
        boardItem.classList.add('board-list-item-active');
      }

      // Add click handler to select board
      boardItem.addEventListener('click', () => {
        this.selectBoard(board.id);
      });

      container.appendChild(boardItem);
    });
  },

  selectBoard(boardId) {
    // Set current board ID
    this.currentBoardId = boardId;

    // Update active class in list
    const container = document.getElementById('board-list');
    if (container) {
      const items = container.querySelectorAll('.board-list-item');
      items.forEach(item => {
        if (item.dataset.boardId === boardId) {
          item.classList.add('board-list-item-active');
        } else {
          item.classList.remove('board-list-item-active');
        }
      });
    }

    // Call onBoardSelect callback
    if (this.onBoardSelect && typeof this.onBoardSelect === 'function') {
      this.onBoardSelect(boardId);
    }
  },

  async createBoard() {
    try {
      // Show input modal for board name
      const name = await InputModal.show('New Board', 'Enter board name');

      // If user cancels, do nothing
      if (name === null) {
        return;
      }

      // If empty string, show error
      if (name === '') {
        Toast.error('Board name is required');
        return;
      }

      // Add loading class
      const container = document.getElementById('board-list');
      if (container) {
        container.classList.add('loading');
      }

      // Create board via API (pass name as string, not object)
      const newBoard = await boardsApi.create(name);

      // Show success message
      Toast.success('Board created');

      // Reload boards and select new board
      await this.loadBoards();
      this.selectBoard(newBoard.id);
    } catch (err) {
      Toast.error('Failed to create board');
      console.error('BoardManager.createBoard failed:', err);
    } finally {
      // Remove loading class
      const container = document.getElementById('board-list');
      if (container) {
        container.classList.remove('loading');
      }
    }
  },

  async deleteBoard() {
    // If no current board, return
    if (!this.currentBoardId) {
      return;
    }

    try {
      // Find current board name
      const currentBoard = this.boards.find(b => b.id === this.currentBoardId);
      const boardName = currentBoard ? currentBoard.name : 'this board';

      // Show confirmation modal
      const confirmed = await ConfirmModal.show(
        'Delete Board',
        `Delete "${boardName}" and all its contents?`
      );

      // If not confirmed, return
      if (!confirmed) {
        return;
      }

      // Add loading class
      const container = document.getElementById('board-list');
      if (container) {
        container.classList.add('loading');
      }

      // Delete board via API
      await boardsApi.delete(this.currentBoardId);

      // Show success message
      Toast.success('Board deleted');

      // Reload boards
      await this.loadBoards();

      // Select first board or show empty state
      if (this.boards.length > 0) {
        this.selectBoard(this.boards[0].id);
      } else {
        this.currentBoardId = null;
        if (this.onBoardSelect && typeof this.onBoardSelect === 'function') {
          this.onBoardSelect(null);
        }
      }
    } catch (err) {
      Toast.error('Failed to delete board');
      console.error('BoardManager.deleteBoard failed:', err);
    } finally {
      // Remove loading class
      const container = document.getElementById('board-list');
      if (container) {
        container.classList.remove('loading');
      }
    }
  },

  getCurrentBoardId() {
    return this.currentBoardId;
  },

  setOnBoardSelect(callback) {
    this.onBoardSelect = callback;
  }
};

export default BoardManager;

import BoardManager from './boardManager.js';
import ColumnManager from './columnManager.js';
import DragDropManager from './dragDrop.js';
import Toast from './toast.js';

document.addEventListener('DOMContentLoaded', async () => {
  try {
    // Get DOM references
    const columnsContainer = document.getElementById('columns-container');
    const addColumnBtn = document.getElementById('add-column-btn');
    const deleteBoardBtn = document.getElementById('delete-board-btn');
    const boardTitle = document.getElementById('board-title');

    // Initialize ColumnManager
    ColumnManager.init(columnsContainer);

    // Initialize DragDropManager
    DragDropManager.init(columnsContainer);

    // Set up BoardManager callback
    BoardManager.setOnBoardSelect(async (boardId) => {
      try {
        // Get the current board's data to update title
        const boards = BoardManager.boards || [];
        const currentBoard = boards.find(board => board.id === boardId);

        if (currentBoard) {
          boardTitle.textContent = currentBoard.name;
        }

        // Load columns for selected board
        await ColumnManager.loadColumns(boardId);
      } catch (err) {
        Toast.error('Failed to load board data');
        console.error('Board select callback failed:', err);
      }
    });

    // Initialize BoardManager (loads boards and auto-selects first one)
    await BoardManager.init();

    // Handle empty state (no boards)
    const currentBoardId = BoardManager.getCurrentBoardId();
    if (!currentBoardId) {
      boardTitle.textContent = 'No Board Selected';
      const emptyState = document.getElementById('empty-state');
      if (emptyState) {
        emptyState.classList.remove('hidden');
      }
    }

    // Set up button handlers
    addColumnBtn.addEventListener('click', async () => {
      const boardId = BoardManager.getCurrentBoardId();
      if (boardId) {
        await ColumnManager.createColumn(boardId);
      } else {
        Toast.info('Please select or create a board first');
      }
    });

    deleteBoardBtn.addEventListener('click', async () => {
      await BoardManager.deleteBoard();
    });

  } catch (err) {
    Toast.error('Failed to initialize application');
    console.error('Application initialization failed:', err);
  }
});

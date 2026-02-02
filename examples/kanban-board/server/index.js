import express from 'express';
import cors from 'cors';
import db from './db.js';

const app = express();
const PORT = 3000;

// Middleware
app.use(express.json());
app.use(cors());
app.use(express.static('public'));

// ========== BOARDS API ==========

// GET /api/boards - Return array of all boards
app.get('/api/boards', (req, res) => {
  const boards = Array.from(db.boards.values());
  res.json(boards);
});

// POST /api/boards - Create board
app.post('/api/boards', (req, res) => {
  const { name } = req.body;

  if (!name) {
    return res.status(400).json({ error: 'Name is required' });
  }

  const now = new Date().toISOString();
  const board = {
    id: db.generateId(),
    name,
    created_at: now,
    updated_at: now
  };

  db.boards.set(board.id, board);
  res.json(board);
});

// GET /api/boards/:id - Return board with nested columns and cards
app.get('/api/boards/:id', (req, res) => {
  const board = db.boards.get(req.params.id);

  if (!board) {
    return res.status(404).json({ error: 'Board not found' });
  }

  // Get columns for this board, sorted by position
  const columns = Array.from(db.columns.values())
    .filter(col => col.board_id === board.id)
    .sort((a, b) => a.position - b.position);

  // Add cards to each column
  const columnsWithCards = columns.map(column => {
    const cards = Array.from(db.cards.values())
      .filter(card => card.column_id === column.id)
      .sort((a, b) => a.position - b.position);

    return {
      ...column,
      cards
    };
  });

  res.json({
    ...board,
    columns: columnsWithCards
  });
});

// PUT /api/boards/:id - PARTIAL update
app.put('/api/boards/:id', (req, res) => {
  const board = db.boards.get(req.params.id);

  if (!board) {
    return res.status(404).json({ error: 'Board not found' });
  }

  const { name } = req.body;
  const updatedBoard = {
    ...board,
    updated_at: new Date().toISOString()
  };

  if (name !== undefined) {
    updatedBoard.name = name;
  }

  db.boards.set(board.id, updatedBoard);
  res.json(updatedBoard);
});

// DELETE /api/boards/:id - Delete board and ALL its columns and cards
app.delete('/api/boards/:id', (req, res) => {
  const board = db.boards.get(req.params.id);

  if (!board) {
    return res.status(404).json({ error: 'Board not found' });
  }

  // Get all columns for this board
  const columnIds = Array.from(db.columns.values())
    .filter(col => col.board_id === board.id)
    .map(col => col.id);

  // Delete all cards in those columns
  Array.from(db.cards.entries()).forEach(([cardId, card]) => {
    if (columnIds.includes(card.column_id)) {
      db.cards.delete(cardId);
    }
  });

  // Delete all columns
  columnIds.forEach(colId => db.columns.delete(colId));

  // Delete the board
  db.boards.delete(board.id);

  res.json({ success: true });
});

// ========== COLUMNS API ==========

// GET /api/boards/:boardId/columns - Return array of columns for board, sorted by position
app.get('/api/boards/:boardId/columns', (req, res) => {
  const columns = Array.from(db.columns.values())
    .filter(col => col.board_id === req.params.boardId)
    .sort((a, b) => a.position - b.position);

  res.json(columns);
});

// POST /api/boards/:boardId/columns - Create column
app.post('/api/boards/:boardId/columns', (req, res) => {
  const { title, position } = req.body;
  const boardId = req.params.boardId;

  if (!title) {
    return res.status(400).json({ error: 'Title is required' });
  }

  const board = db.boards.get(boardId);
  if (!board) {
    return res.status(404).json({ error: 'Board not found' });
  }

  // If position not provided, append to end
  let finalPosition = position;
  if (finalPosition === undefined) {
    const existingColumns = Array.from(db.columns.values())
      .filter(col => col.board_id === boardId);
    finalPosition = existingColumns.length;
  }

  const column = {
    id: db.generateId(),
    board_id: boardId,
    title,
    position: finalPosition,
    created_at: new Date().toISOString()
  };

  db.columns.set(column.id, column);
  res.json(column);
});

// PUT /api/columns/:id - PARTIAL update
app.put('/api/columns/:id', (req, res) => {
  const column = db.columns.get(req.params.id);

  if (!column) {
    return res.status(404).json({ error: 'Column not found' });
  }

  const { title, position } = req.body;
  const updatedColumn = { ...column };

  if (title !== undefined) {
    updatedColumn.title = title;
  }

  if (position !== undefined) {
    updatedColumn.position = position;
  }

  db.columns.set(column.id, updatedColumn);
  res.json(updatedColumn);
});

// DELETE /api/columns/:id - Delete column and ALL its cards
app.delete('/api/columns/:id', (req, res) => {
  const column = db.columns.get(req.params.id);

  if (!column) {
    return res.status(404).json({ error: 'Column not found' });
  }

  // Delete all cards in this column
  Array.from(db.cards.entries()).forEach(([cardId, card]) => {
    if (card.column_id === column.id) {
      db.cards.delete(cardId);
    }
  });

  // Delete the column
  db.columns.delete(column.id);

  res.json({ success: true });
});

// PUT /api/columns/:id/reorder - Reorder cards
app.put('/api/columns/:id/reorder', (req, res) => {
  const { card_ids } = req.body;
  const columnId = req.params.id;

  if (!Array.isArray(card_ids)) {
    return res.status(400).json({ error: 'card_ids must be an array' });
  }

  // Update position of each card based on array index
  card_ids.forEach((cardId, index) => {
    const card = db.cards.get(cardId);
    if (card && card.column_id === columnId) {
      db.cards.set(cardId, {
        ...card,
        position: index
      });
    }
  });

  res.json({ success: true });
});

// ========== CARDS API ==========

// GET /api/columns/:columnId/cards - Return array of cards for column, sorted by position
app.get('/api/columns/:columnId/cards', (req, res) => {
  const cards = Array.from(db.cards.values())
    .filter(card => card.column_id === req.params.columnId)
    .sort((a, b) => a.position - b.position);

  res.json(cards);
});

// POST /api/columns/:columnId/cards - Create card
app.post('/api/columns/:columnId/cards', (req, res) => {
  const { title, description, position, labels, due_date } = req.body;
  const columnId = req.params.columnId;

  if (!title) {
    return res.status(400).json({ error: 'Title is required' });
  }

  const column = db.columns.get(columnId);
  if (!column) {
    return res.status(404).json({ error: 'Column not found' });
  }

  // If position not provided, append to end
  let finalPosition = position;
  if (finalPosition === undefined) {
    const existingCards = Array.from(db.cards.values())
      .filter(card => card.column_id === columnId);
    finalPosition = existingCards.length;
  }

  const card = {
    id: db.generateId(),
    column_id: columnId,
    title,
    description: description || null,
    position: finalPosition,
    labels: labels || [],
    due_date: due_date || null,
    created_at: new Date().toISOString()
  };

  db.cards.set(card.id, card);
  res.json(card);
});

// PUT /api/cards/:id - PARTIAL update
app.put('/api/cards/:id', (req, res) => {
  const card = db.cards.get(req.params.id);

  if (!card) {
    return res.status(404).json({ error: 'Card not found' });
  }

  const { title, description, column_id, position, labels, due_date } = req.body;
  const updatedCard = { ...card };

  if (title !== undefined) {
    updatedCard.title = title;
  }

  if (description !== undefined) {
    updatedCard.description = description;
  }

  if (column_id !== undefined) {
    updatedCard.column_id = column_id;
  }

  if (position !== undefined) {
    updatedCard.position = position;
  }

  if (labels !== undefined) {
    updatedCard.labels = labels;
  }

  if (due_date !== undefined) {
    updatedCard.due_date = due_date;
  }

  db.cards.set(card.id, updatedCard);
  res.json(updatedCard);
});

// DELETE /api/cards/:id - Delete card
app.delete('/api/cards/:id', (req, res) => {
  const card = db.cards.get(req.params.id);

  if (!card) {
    return res.status(404).json({ error: 'Card not found' });
  }

  db.cards.delete(card.id);
  res.json({ success: true });
});

// ========== START SERVER ==========

app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});

import { v4 as uuidv4 } from 'uuid';

// In-memory database using Maps
const db = {
  boards: new Map(),
  columns: new Map(),
  cards: new Map(),

  // UUID generator function
  generateId() {
    return uuidv4();
  }
};

// Seed sample data
function seedDatabase() {
  const now = new Date().toISOString();

  // Create one board
  const boardId = db.generateId();
  db.boards.set(boardId, {
    id: boardId,
    name: "My First Board",
    created_at: now,
    updated_at: now
  });

  // Create three columns
  const todoColumnId = db.generateId();
  db.columns.set(todoColumnId, {
    id: todoColumnId,
    board_id: boardId,
    title: "To Do",
    position: 0,
    created_at: now
  });

  const inProgressColumnId = db.generateId();
  db.columns.set(inProgressColumnId, {
    id: inProgressColumnId,
    board_id: boardId,
    title: "In Progress",
    position: 1,
    created_at: now
  });

  const doneColumnId = db.generateId();
  db.columns.set(doneColumnId, {
    id: doneColumnId,
    board_id: boardId,
    title: "Done",
    position: 2,
    created_at: now
  });

  // Create two sample cards in "To Do" column
  const card1Id = db.generateId();
  db.cards.set(card1Id, {
    id: card1Id,
    column_id: todoColumnId,
    title: "Design new landing page",
    description: "Create mockups and design system for the new landing page",
    position: 0,
    labels: ["design", "high-priority"],
    due_date: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(), // 7 days from now
    created_at: now
  });

  const card2Id = db.generateId();
  db.cards.set(card2Id, {
    id: card2Id,
    column_id: todoColumnId,
    title: "Set up CI/CD pipeline",
    description: "Configure automated testing and deployment",
    position: 1,
    labels: ["devops", "infrastructure"],
    due_date: null,
    created_at: now
  });
}

// Initialize database with sample data
seedDatabase();

export default db;

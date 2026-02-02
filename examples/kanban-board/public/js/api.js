// API module for handling all HTTP requests to the backend

/**
 * Internal helper function to make HTTP requests
 * @param {string} method - HTTP method (GET, POST, PUT, DELETE)
 * @param {string} path - API endpoint path
 * @param {object} [body] - Request body (will be JSON stringified)
 * @returns {Promise<any>} Parsed JSON response
 * @throws {Error} On non-ok response with error message from API
 */
async function request(method, path, body) {
  const options = {
    method,
    headers: {}
  };

  if (body !== undefined) {
    options.headers['Content-Type'] = 'application/json';
    options.body = JSON.stringify(body);
  }

  const response = await fetch(path, options);

  if (!response.ok) {
    let errorMessage = response.statusText;
    try {
      const errorData = await response.json();
      if (errorData.error) {
        errorMessage = errorData.error;
      }
    } catch (e) {
      // If parsing error response fails, use statusText
    }
    throw new Error(errorMessage);
  }

  return await response.json();
}

// Boards API
const boardsApi = {
  /**
   * Get all boards
   * @returns {Promise<Board[]>}
   */
  async getAll() {
    return await request('GET', '/api/boards');
  },

  /**
   * Get board by ID
   * @param {string} id - Board ID
   * @returns {Promise<Board>}
   */
  async getById(id) {
    return await request('GET', `/api/boards/${id}`);
  },

  /**
   * Create a new board
   * @param {string} name - Board name (NOT an object, just the string)
   * @returns {Promise<Board>}
   */
  async create(name) {
    return await request('POST', '/api/boards', { name });
  },

  /**
   * Update board
   * @param {string} id - Board ID
   * @param {object} data - Update data { name?: string }
   * @returns {Promise<Board>}
   */
  async update(id, data) {
    return await request('PUT', `/api/boards/${id}`, data);
  },

  /**
   * Delete board
   * @param {string} id - Board ID
   * @returns {Promise<{ success: boolean }>}
   */
  async delete(id) {
    return await request('DELETE', `/api/boards/${id}`);
  }
};

// Columns API
const columnsApi = {
  /**
   * Get all columns for a board
   * @param {string} boardId - Board ID
   * @returns {Promise<Column[]>}
   */
  async getByBoard(boardId) {
    return await request('GET', `/api/boards/${boardId}/columns`);
  },

  /**
   * Create a new column
   * @param {string} boardId - Board ID
   * @param {string} title - Column title
   * @param {number} position - Column position
   * @returns {Promise<Column>}
   */
  async create(boardId, title, position) {
    return await request('POST', `/api/boards/${boardId}/columns`, { title, position });
  },

  /**
   * Update column
   * @param {string} id - Column ID
   * @param {object} data - Update data { title?: string, position?: number }
   * @returns {Promise<Column>}
   */
  async update(id, data) {
    return await request('PUT', `/api/columns/${id}`, data);
  },

  /**
   * Delete column
   * @param {string} id - Column ID
   * @returns {Promise<{ success: boolean }>}
   */
  async delete(id) {
    return await request('DELETE', `/api/columns/${id}`);
  },

  /**
   * Reorder cards in a column
   * @param {string} id - Column ID
   * @param {string[]} cardIds - Ordered array of card IDs
   * @returns {Promise<{ success: boolean }>}
   */
  async reorder(id, cardIds) {
    return await request('PUT', `/api/columns/${id}/reorder`, { card_ids: cardIds });
  }
};

// Cards API
const cardsApi = {
  /**
   * Get all cards for a column
   * @param {string} columnId - Column ID
   * @returns {Promise<Card[]>}
   */
  async getByColumn(columnId) {
    return await request('GET', `/api/columns/${columnId}/cards`);
  },

  /**
   * Create a new card
   * @param {string} columnId - Column ID
   * @param {object} data - Card data { title: string, description?: string, position?: number, labels?: string[], due_date?: string }
   * @returns {Promise<Card>}
   */
  async create(columnId, data) {
    return await request('POST', `/api/columns/${columnId}/cards`, data);
  },

  /**
   * Update card
   * @param {string} id - Card ID
   * @param {object} data - Update data { title?: string, description?: string, column_id?: string, position?: number, labels?: string[], due_date?: string }
   * @returns {Promise<Card>}
   */
  async update(id, data) {
    return await request('PUT', `/api/cards/${id}`, data);
  },

  /**
   * Delete card
   * @param {string} id - Card ID
   * @returns {Promise<{ success: boolean }>}
   */
  async delete(id) {
    return await request('DELETE', `/api/cards/${id}`);
  }
};

export { boardsApi, columnsApi, cardsApi };

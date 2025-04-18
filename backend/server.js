
const express = require('express');
const cors = require('cors');
const mysql = require('mysql2/promise');
const bodyParser = require('body-parser');
const dotenv = require('dotenv');

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3001;


app.use(cors());
app.use(bodyParser.json());


const pool = mysql.createPool({
  host: process.env.DB_HOST || 'localhost',
  user: process.env.DB_USER || 'root',
  password: process.env.DB_PASSWORD || 'Ritesh@/2004',
  database: process.env.DB_NAME || 'fraud_detection',
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0
});

// New Login Endpoint
app.post('/api/login', async (req, res) => {
  try {
    const { email, password } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required.' });
    }
    // Call the stored procedure UserLogin
    const [rows] = await pool.query('CALL UserLogin(?, ?)', [email, password]);
    // The stored procedure returns results in rows[0]
    if (rows[0] && rows[0].length > 0) {
      const user = rows[0][0];
      // Optionally update the last_login timestamp
      await pool.query('UPDATE users SET last_login = NOW() WHERE user_id = ?', [user.user_id]);
      return res.json(user);
    } else {
      return res.status(401).json({ error: 'Invalid credentials' });
    }
  } catch (error) {
    console.error('Error during login:', error);
    res.status(500).json({ error: 'Failed to login user' });
  }
});

// 1. User Management
app.get('/api/users', async (req, res) => {
  try {
    const [rows] = await pool.query(`
      SELECT user_id, username, email, created_at, last_login, 
             account_status, risk_score 
      FROM users
      ORDER BY risk_score DESC
    `);
    res.json(rows);
  } catch (error) {
    console.error('Error fetching users:', error);
    res.status(500).json({ error: 'Failed to fetch users' });
  }
});

app.post('/api/users', async (req, res) => {
  try {
    const { username, email } = req.body;
    const [result] = await pool.query(
      'INSERT INTO users (username, email) VALUES (?, ?)',
      [username, email]
    );
    res.status(201).json({ id: result.insertId, username, email });
  } catch (error) {
    console.error('Error creating user:', error);
    res.status(500).json({ error: 'Failed to create user' });
  }
});

app.put('/api/users/:id/status', async (req, res) => {
  try {
    const { id } = req.params;
    const { status } = req.body;
    await pool.query(
      'UPDATE users SET account_status = ? WHERE user_id = ?',
      [status, id]
    );
    res.json({ message: 'User status updated successfully' });
  } catch (error) {
    console.error('Error updating user status:', error);
    res.status(500).json({ error: 'Failed to update user status' });
  }
});

// 2. Merchants
app.get('/api/merchants', async (req, res) => {
  try {
    const [rows] = await pool.query(`
      SELECT merchant_id, name, category, risk_category, registered_at
      FROM merchants
    `);
    res.json(rows);
  } catch (error) {
    console.error('Error fetching merchants:', error);
    res.status(500).json({ error: 'Failed to fetch merchants' });
  }
});

app.post('/api/merchants', async (req, res) => {
  try {
    const { name, category, risk_category } = req.body;
    const [result] = await pool.query(
      'INSERT INTO merchants (name, category, risk_category) VALUES (?, ?, ?)',
      [name, category, risk_category || 'LOW']
    );
    res.status(201).json({ 
      id: result.insertId, 
      name, 
      category, 
      risk_category: risk_category || 'LOW' 
    });
  } catch (error) {
    console.error('Error creating merchant:', error);
    res.status(500).json({ error: 'Failed to create merchant' });
  }
});

// 3. Transactions
app.get('/api/transactions', async (req, res) => {
  try {
    const [rows] = await pool.query(`
      SELECT t.transaction_id, t.amount, t.currency, t.transaction_time,
             t.status, t.device_hash, ST_X(t.location) as longitude, 
             ST_Y(t.location) as latitude, u.username, m.name as merchant_name
      FROM transactions t
      JOIN users u ON t.user_id = u.user_id
      JOIN merchants m ON t.merchant_id = m.merchant_id
      ORDER BY t.transaction_time DESC
      LIMIT 100
    `);
    res.json(rows);
  } catch (error) {
    console.error('Error fetching transactions:', error);
    res.status(500).json({ error: 'Failed to fetch transactions' });
  }
});

// Updated POST endpoint for Transactions
app.post('/api/transactions', async (req, res) => {
  try {
    const { user_id, merchant_id, amount, latitude, longitude, device_hash } = req.body;
    // Call the stored procedure CreateTransaction
    const [result] = await pool.query(
      'CALL CreateTransaction(?, ?, ?, ?, ?, ?)',
      [user_id, merchant_id, amount, latitude, longitude, device_hash]
    );
    // Log result structure for debugging
    console.log("Stored Procedure Result:", result);

    // Extract the new transaction ID; assumes procedure returns a result set with transaction_id
    const transactionId = result && result[0] && result[0][0] 
      ? result[0][0].transaction_id 
      : null;

    if (!transactionId) {
      throw new Error("Transaction ID not returned from stored procedure.");
    }

    res.status(201).json({ 
      message: 'Transaction processed successfully',
      transaction_id: transactionId
    });
  } catch (error) {
    console.error('Error creating transaction:', error);
    res.status(500).json({ error: 'Failed to create transaction' });
  }
});

// 4. Fraud Rules
app.get('/api/fraud-rules', async (req, res) => {
  try {
    const [rows] = await pool.query(`
      SELECT rule_id, rule_name, description, \`condition\`, 
             severity_level, is_active, created_at, updated_at
      FROM fraud_rules
    `);
    res.json(rows);
  } catch (error) {
    console.error('Error fetching fraud rules:', error);
    res.status(500).json({ error: 'Failed to fetch fraud rules' });
  }
});

app.post('/api/fraud-rules', async (req, res) => {
  try {
    const { rule_name, description, condition, severity_level } = req.body;
    const [result] = await pool.query(
      'INSERT INTO fraud_rules (rule_name, description, `condition`, severity_level) VALUES (?, ?, ?, ?)',
      [rule_name, description, condition, severity_level]
    );
    res.status(201).json({ 
      id: result.insertId, 
      rule_name, 
      description, 
      condition,
      severity_level 
    });
  } catch (error) {
    console.error('Error creating fraud rule:', error);
    res.status(500).json({ error: 'Failed to create fraud rule' });
  }
});

app.put('/api/fraud-rules/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const { condition, is_active } = req.body;
    // Using the stored procedure to update a fraud rule
    await pool.query(
      'CALL UpdateFraudRule(?, ?, ?)',
      [id, condition, is_active]
    );
    res.json({ message: 'Fraud rule updated successfully' });
  } catch (error) {
    console.error('Error updating fraud rule:', error);
    res.status(500).json({ error: 'Failed to update fraud rule' });
  }
});

// 5. Fraud Flags (Updated to include location points from transactions)
app.get('/api/fraud-flags', async (req, res) => {
  try {
    const [rows] = await pool.query(`
      SELECT 
        f.flag_id, f.transaction_id, f.flagged_at, f.is_confirmed,
        f.investigation_status, f.notes, r.rule_name, r.severity_level,
        t.amount, u.username, m.name as merchant_name,
        ST_X(t.location) AS longitude, ST_Y(t.location) AS latitude
      FROM fraud_flags f
      JOIN transactions t ON f.transaction_id = t.transaction_id
      JOIN users u ON t.user_id = u.user_id
      JOIN merchants m ON t.merchant_id = m.merchant_id
      JOIN fraud_rules r ON f.rule_id = r.rule_id
      ORDER BY f.flagged_at DESC
      LIMIT 100
    `);
    res.json(rows);
  } catch (error) {
    console.error('Error fetching fraud flags:', error);
    res.status(500).json({ error: 'Failed to fetch fraud flags' });
  }
});

app.put('/api/fraud-flags/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const { is_confirmed, investigation_status, notes } = req.body;
    await pool.query(
      'UPDATE fraud_flags SET is_confirmed = ?, investigation_status = ?, notes = ? WHERE flag_id = ?',
      [is_confirmed, investigation_status, notes, id]
    );
    res.json({ message: 'Fraud flag updated successfully' });
  } catch (error) {
    console.error('Error updating fraud flag:', error);
    res.status(500).json({ error: 'Failed to update fraud flag' });
  }
});

// 6. Dashboard Stats
app.get('/api/dashboard/stats', async (req, res) => {
  try {
    // Get total transactions
    const [totalTransactions] = await pool.query('SELECT COUNT(*) as count FROM transactions');
    
    // Get flagged transactions
    const [flaggedTransactions] = await pool.query('SELECT COUNT(*) as count FROM fraud_flags');
    
    // Get confirmed fraud
    const [confirmedFraud] = await pool.query('SELECT COUNT(*) as count FROM fraud_flags WHERE is_confirmed = TRUE');
    
    // Get high-risk users
    const [highRiskUsers] = await pool.query('SELECT COUNT(*) as count FROM users WHERE risk_score > 0.75');
    
    // Get recent flags
    const [recentFlags] = await pool.query(`
      SELECT 
        f.flagged_at, r.rule_name, r.severity_level, t.amount,
        u.username, m.name as merchant_name
      FROM fraud_flags f
      JOIN transactions t ON f.transaction_id = t.transaction_id
      JOIN users u ON t.user_id = u.user_id
      JOIN merchants m ON t.merchant_id = m.merchant_id
      JOIN fraud_rules r ON f.rule_id = r.rule_id
      ORDER BY f.flagged_at DESC
      LIMIT 5
    `);
    
    res.json({
      total_transactions: totalTransactions[0].count,
      flagged_transactions: flaggedTransactions[0].count,
      confirmed_fraud: confirmedFraud[0].count,
      high_risk_users: highRiskUsers[0].count,
      recent_flags: recentFlags
    });
  } catch (error) {
    console.error('Error fetching dashboard stats:', error);
    res.status(500).json({ error: 'Failed to fetch dashboard stats' });
  }
});

// Start the server
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});

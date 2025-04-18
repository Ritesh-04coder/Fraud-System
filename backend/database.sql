-- Create the fraud_detection database
CREATE DATABASE  fraud_detection;
USE fraud_detection;


-- Create users table
CREATE TABLE IF NOT EXISTS users (
  user_id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(100) NOT NULL UNIQUE,
  email VARCHAR(255) NOT NULL UNIQUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  last_login TIMESTAMP NULL,
  account_status ENUM('ACTIVE', 'SUSPENDED', 'INACTIVE', 'LOCKED') DEFAULT 'ACTIVE',
  risk_score DECIMAL(5,2) DEFAULT 0.00,
  password VARCHAR(255) NOT NULL DEFAULT '',
  INDEX idx_risk_score (risk_score)
);

-- Create merchants table
CREATE TABLE IF NOT EXISTS merchants (
  merchant_id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  category VARCHAR(50) NOT NULL,
  risk_category ENUM('LOW', 'MEDIUM', 'HIGH') DEFAULT 'LOW',
  registered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create transactions table with geospatial location
CREATE TABLE IF NOT EXISTS transactions (
  transaction_id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  merchant_id INT NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  currency VARCHAR(3) DEFAULT 'USD',
  transaction_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status ENUM('PENDING', 'COMPLETED', 'FAILED', 'REVERSED') DEFAULT 'COMPLETED',
  device_hash VARCHAR(64),
  location POINT,
  is_flagged BOOLEAN DEFAULT FALSE,
  FOREIGN KEY (user_id) REFERENCES users(user_id),
  FOREIGN KEY (merchant_id) REFERENCES merchants(merchant_id),
  INDEX idx_transaction_time (transaction_time),
  INDEX idx_user_id (user_id),
  INDEX idx_merchant_id (merchant_id),
  INDEX idx_is_flagged (is_flagged)
);

-- Create fraud_rules table
CREATE TABLE IF NOT EXISTS fraud_rules (
  rule_id INT AUTO_INCREMENT PRIMARY KEY,
  rule_name VARCHAR(100) NOT NULL,
  description TEXT,
  `condition` TEXT NOT NULL,
  severity_level ENUM('LOW', 'MEDIUM', 'HIGH') NOT NULL,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- Create fraud_flags table
CREATE TABLE IF NOT EXISTS fraud_flags (
  flag_id INT AUTO_INCREMENT PRIMARY KEY,
  transaction_id INT NOT NULL,
  rule_id INT NOT NULL,
  flagged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  is_confirmed BOOLEAN DEFAULT FALSE,
  investigation_status ENUM('PENDING', 'IN_PROGRESS', 'CONFIRMED', 'RESOLVED') DEFAULT 'PENDING',
  notes TEXT,
  FOREIGN KEY (transaction_id) REFERENCES transactions(transaction_id),
  FOREIGN KEY (rule_id) REFERENCES fraud_rules(rule_id),
  INDEX idx_flagged_at (flagged_at)
);

-- ===============================
-- Create Stored Procedures
-- ===============================

-- Stored Procedure: CreateTransaction
DELIMITER $$
CREATE PROCEDURE CreateTransaction(
  IN p_user_id INT,
  IN p_merchant_id INT,
  IN p_amount DECIMAL(10,2),
  IN p_latitude DECIMAL(10,8),
  IN p_longitude DECIMAL(11,8),
  IN p_device_hash VARCHAR(64)
)
BEGIN
  DECLARE last_transaction_id INT;
  
  -- Insert the transaction with geospatial POINT for location.
  INSERT INTO transactions (user_id, merchant_id, amount, device_hash, location)
  VALUES (p_user_id, p_merchant_id, p_amount, p_device_hash, POINT(p_longitude, p_latitude));
  
  -- Retrieve the auto-generated transaction_id.
  SET last_transaction_id = LAST_INSERT_ID();
  
  -- Execute fraud rules evaluation for the new transaction.
  CALL EvaluateFraudRules(last_transaction_id);
  
  -- Update user risk score based on the new transaction.
  CALL UpdateUserRiskScore(p_user_id);
  
  -- Return the new transaction ID for backend usage.
  SELECT last_transaction_id AS transaction_id;
END$$
DELIMITER ;

-- Stored Procedure: EvaluateFraudRules
DELIMITER $$
CREATE PROCEDURE EvaluateFraudRules(IN p_transaction_id INT)
BEGIN
  DECLARE v_user_id INT;
  DECLARE v_merchant_id INT;
  DECLARE v_amount DECIMAL(10,2);
  DECLARE v_longitude DECIMAL(11,8);
  DECLARE v_latitude DECIMAL(10,8);
  
  -- Retrieve transaction details into local variables.
  SELECT user_id, merchant_id, amount, 
         ST_X(location) as longitude, 
         ST_Y(location) as latitude
  INTO v_user_id, v_merchant_id, v_amount, v_longitude, v_latitude
  FROM transactions
  WHERE transaction_id = p_transaction_id;
  
  -- Rule 1: If transaction amount is over $1000.
  IF v_amount > 1000 THEN
    INSERT INTO fraud_flags (transaction_id, rule_id)
    SELECT p_transaction_id, rule_id FROM fraud_rules 
    WHERE rule_name = 'Large Transaction' AND is_active = TRUE;
    
    UPDATE transactions SET is_flagged = TRUE 
    WHERE transaction_id = p_transaction_id;
  END IF;
  
  -- Rule 2: If transaction is with a high-risk merchant.
  IF EXISTS (SELECT 1 FROM merchants 
             WHERE merchant_id = v_merchant_id 
             AND risk_category = 'HIGH') THEN
    INSERT INTO fraud_flags (transaction_id, rule_id)
    SELECT p_transaction_id, rule_id FROM fraud_rules 
    WHERE rule_name = 'High Risk Merchant' AND is_active = TRUE;
    
    UPDATE transactions SET is_flagged = TRUE 
    WHERE transaction_id = p_transaction_id;
  END IF;
  
  -- Rule 3: If more than 5 transactions occur for the user in the last hour.
  IF (SELECT COUNT(*) FROM transactions 
      WHERE user_id = v_user_id 
      AND transaction_time >= DATE_SUB(NOW(), INTERVAL 1 HOUR)) > 5 THEN
    INSERT INTO fraud_flags (transaction_id, rule_id)
    SELECT p_transaction_id, rule_id FROM fraud_rules 
    WHERE rule_name = 'Multiple Transactions' AND is_active = TRUE;
    
    UPDATE transactions SET is_flagged = TRUE 
    WHERE transaction_id = p_transaction_id;
  END IF;
  
  -- Rule 4: If the transaction location is more than 1000km away from a previous transaction.
  IF EXISTS (
    SELECT 1 FROM transactions t
    WHERE t.user_id = v_user_id
      AND t.transaction_id != p_transaction_id
      AND t.transaction_time >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
      AND ST_Distance_Sphere(t.location, POINT(v_longitude, v_latitude)) > 1000000
    LIMIT 1
  ) THEN
    INSERT INTO fraud_flags (transaction_id, rule_id)
    SELECT p_transaction_id, rule_id FROM fraud_rules 
    WHERE rule_name = 'Unusual Location' AND is_active = TRUE;
    
    UPDATE transactions SET is_flagged = TRUE 
    WHERE transaction_id = p_transaction_id;
  END IF;
END$$
DELIMITER ;

-- Stored Procedure: UpdateUserRiskScore
DELIMITER $$
CREATE PROCEDURE UpdateUserRiskScore(IN p_user_id INT)
BEGIN
  DECLARE v_recent_flags INT;
  DECLARE v_total_transactions INT;
  DECLARE v_new_risk_score DECIMAL(5,2);
  
  -- Count the number of fraud flags for the user in the last 30 days.
  SELECT COUNT(*) INTO v_recent_flags
  FROM fraud_flags f
  JOIN transactions t ON f.transaction_id = t.transaction_id
  WHERE t.user_id = p_user_id
    AND f.flagged_at >= DATE_SUB(NOW(), INTERVAL 30 DAY);
  
  -- Count the total transactions for the user in the last 30 days.
  SELECT COUNT(*) INTO v_total_transactions
  FROM transactions
  WHERE user_id = p_user_id
    AND transaction_time >= DATE_SUB(NOW(), INTERVAL 30 DAY);
  
  -- Calculate the new risk score if transactions exist.
  IF v_total_transactions > 0 THEN
    SET v_new_risk_score = (v_recent_flags / v_total_transactions) * 0.7 + 
                           (SELECT COALESCE(risk_score, 0) FROM users WHERE user_id = p_user_id) * 0.3;
    IF v_new_risk_score > 1.0 THEN
      SET v_new_risk_score = 1.0;
    END IF;
    
    UPDATE users SET risk_score = v_new_risk_score WHERE user_id = p_user_id;
  END IF;
END$$
DELIMITER ;

-- Stored Procedure: UpdateFraudRule
DELIMITER $$
CREATE PROCEDURE UpdateFraudRule(
  IN p_rule_id INT,
  IN p_condition TEXT,
  IN p_is_active BOOLEAN
)
BEGIN
  UPDATE fraud_rules
  SET `condition` = COALESCE(p_condition, `condition`),
      is_active = COALESCE(p_is_active, is_active),
      updated_at = CURRENT_TIMESTAMP
  WHERE rule_id = p_rule_id;
END$$
DELIMITER ;

-- ===============================
-- Insert Sample Data
-- ===============================

-- Sample Users
INSERT INTO users (username, email, account_status, risk_score, password) VALUES
('john_doe', 'john@example.com', 'ACTIVE', 0.10, 'password123'),
('jane_smith', 'jane@example.com', 'ACTIVE', 0.05, 'password123'),
('bob_johnson', 'bob@example.com', 'ACTIVE', 0.42, 'password123'),
('alice_wong', 'alice@example.com', 'ACTIVE', 0.15, 'password123'),
('mike_brown', 'mike@example.com', 'ACTIVE', 0.80, 'password123'),
('emily_davis', 'emily@example.com', 'SUSPENDED', 0.95, 'password123'),
('david_wilson', 'david@example.com', 'ACTIVE', 0.30, 'password123'),
('sarah_lee', 'sarah@example.com', 'ACTIVE', 0.25, 'password123'),
('tom_garcia', 'tom@example.com', 'LOCKED', 0.88, 'password123'),
('lisa_martinez', 'lisa@example.com', 'ACTIVE', 0.12, 'password123');

-- Sample Merchants
INSERT INTO merchants (name, category, risk_category) VALUES
('Amazon', 'Retail', 'LOW'),
('Walmart', 'Retail', 'LOW'),
('Best Buy', 'Electronics', 'LOW'),
('Apple Store', 'Electronics', 'LOW'),
('QuickCash ATM', 'Finance', 'MEDIUM'),
('LuxuryGoods Online', 'Luxury', 'MEDIUM'),
('CryptoExchange', 'Cryptocurrency', 'HIGH'),
('FastPayments', 'Finance', 'MEDIUM'),
('OnlineGamingHub', 'Gaming', 'HIGH'),
('TravelNow', 'Travel', 'LOW');

-- Sample Fraud Rules
INSERT INTO fraud_rules (rule_name, description, `condition`, severity_level) VALUES
('Large Transaction', 'Transaction amount exceeds $1000', 'amount > 1000', 'MEDIUM'),
('Multiple Transactions', 'More than 5 transactions in an hour', 'transaction_count > 5 AND timespan <= 3600', 'HIGH'),
('Unusual Location', 'Transaction location differs significantly from user history', 'distance > 1000km from prev_transaction', 'HIGH'),
('High Risk Merchant', 'Transaction with merchant marked as high risk', 'merchant.risk_category = HIGH', 'MEDIUM'),
('Unusual Time', 'Transaction occurs during unusual hours for user', 'transaction_hour not in user_active_hours', 'LOW'),
('Device Change', 'Transaction from new or unusual device', 'device_hash not in user_known_devices', 'MEDIUM'),
('Cross-border Transaction', 'Transaction location in different country than user home', 'transaction_country != user_country', 'MEDIUM'),
('Velocity Check', 'Unusual transaction frequency', 'transaction_frequency > user_average * 2', 'HIGH');

-- Sample Transactions (with POINT format for location)
INSERT INTO transactions (user_id, merchant_id, amount, currency, transaction_time, status, device_hash, location) VALUES
(1, 1, 120.50, 'USD', DATE_SUB(NOW(), INTERVAL 2 HOUR), 'COMPLETED', 'a1b2c3d4e5f6', POINT(-74.006, 40.7128)),
(2, 3, 899.99, 'USD', DATE_SUB(NOW(), INTERVAL 3 HOUR), 'COMPLETED', 'b2c3d4e5f6g7', POINT(-122.4194, 37.7749)),
(3, 5, 500.00, 'USD', DATE_SUB(NOW(), INTERVAL 4 HOUR), 'COMPLETED', 'c3d4e5f6g7h8', POINT(-87.6298, 41.8781)),
(4, 2, 76.25, 'USD', DATE_SUB(NOW(), INTERVAL 5 HOUR), 'COMPLETED', 'd4e5f6g7h8i9', POINT(-118.2437, 34.0522)),
(5, 7, 1200.00, 'USD', DATE_SUB(NOW(), INTERVAL 6 HOUR), 'COMPLETED', 'e5f6g7h8i9j0', POINT(-80.1918, 25.7617)),
(6, 9, 350.00, 'USD', DATE_SUB(NOW(), INTERVAL 7 HOUR), 'COMPLETED', 'f6g7h8i9j0k1', POINT(-94.5786, 39.0997)),
(7, 4, 1299.99, 'USD', DATE_SUB(NOW(), INTERVAL 8 HOUR), 'COMPLETED', 'g7h8i9j0k1l2', POINT(-71.0589, 42.3601)),
(8, 10, 875.50, 'USD', DATE_SUB(NOW(), INTERVAL 9 HOUR), 'COMPLETED', 'h8i9j0k1l2m3', POINT(-104.9903, 39.7392)),
(9, 8, 199.99, 'USD', DATE_SUB(NOW(), INTERVAL 10 HOUR), 'COMPLETED', 'i9j0k1l2m3n4', POINT(-95.3698, 29.7604)),
(10, 6, 2500.00, 'USD', DATE_SUB(NOW(), INTERVAL 11 HOUR), 'COMPLETED', 'j0k1l2m3n4o5', POINT(-97.7431, 30.2672)),
(1, 3, 349.99, 'USD', DATE_SUB(NOW(), INTERVAL 12 HOUR), 'COMPLETED', 'a1b2c3d4e5f6', POINT(-74.0060, 40.7128)),
(2, 1, 59.99, 'USD', DATE_SUB(NOW(), INTERVAL 13 HOUR), 'COMPLETED', 'b2c3d4e5f6g7', POINT(-122.4194, 37.7749)),
(3, 7, 1500.00, 'USD', DATE_SUB(NOW(), INTERVAL 14 HOUR), 'COMPLETED', 'c3d4e5f6g7h8', POINT(-0.1278, 51.5074)), -- Unusual location (London)
(4, 4, 129.99, 'USD', DATE_SUB(NOW(), INTERVAL 15 HOUR), 'COMPLETED', 'x4y5z6a7b8c9', POINT(-118.2437, 34.0522)), -- New device
(5, 9, 800.00, 'USD', DATE_SUB(NOW(), INTERVAL 16 HOUR), 'COMPLETED', 'e5f6g7h8i9j0', POINT(-80.1918, 25.7617)),
(6, 8, 450.00, 'USD', DATE_SUB(NOW(), INTERVAL 17 HOUR), 'COMPLETED', 'f6g7h8i9j0k1', POINT(-94.5786, 39.0997)),
(7, 2, 89.99, 'USD', DATE_SUB(NOW(), INTERVAL 18 HOUR), 'COMPLETED', 'g7h8i9j0k1l2', POINT(-71.0589, 42.3601)),
(8, 5, 300.00, 'USD', DATE_SUB(NOW(), INTERVAL 19 HOUR), 'COMPLETED', 'h8i9j0k1l2m3', POINT(-104.9903, 39.7392)),
(5, 7, 950.00, 'USD', DATE_SUB(NOW(), INTERVAL 20 MINUTE), 'COMPLETED', 'e5f6g7h8i9j0', POINT(-80.1918, 25.7617)),
(5, 7, 750.00, 'USD', DATE_SUB(NOW(), INTERVAL 15 MINUTE), 'COMPLETED', 'e5f6g7h8i9j0', POINT(-80.1918, 25.7617)),
(5, 7, 1100.00, 'USD', DATE_SUB(NOW(), INTERVAL 10 MINUTE), 'COMPLETED', 'e5f6g7h8i9j0', POINT(-80.1918, 25.7617)),
(5, 7, 850.00, 'USD', DATE_SUB(NOW(), INTERVAL 5 MINUTE), 'COMPLETED', 'e5f6g7h8i9j0', POINT(-80.1918, 25.7617)),
(5, 7, 1250.00, 'USD', NOW(), 'COMPLETED', 'e5f6g7h8i9j0', POINT(-80.1918, 25.7617));

-- Process transactions to generate fraud flags
CALL EvaluateFraudRules(3);  -- High amount from CashATM
CALL EvaluateFraudRules(5);  -- High risk merchant + high amount
CALL EvaluateFraudRules(7);  -- High amount
CALL EvaluateFraudRules(10); -- Very high amount
CALL EvaluateFraudRules(13); -- Unusual location
CALL EvaluateFraudRules(19); -- Multiple transactions
CALL EvaluateFraudRules(20);
CALL EvaluateFraudRules(21);
CALL EvaluateFraudRules(22);
CALL EvaluateFraudRules(23);

-- Update some flags to different statuses
UPDATE fraud_flags SET investigation_status = 'IN_PROGRESS' WHERE flag_id = 1;
UPDATE fraud_flags SET investigation_status = 'CONFIRMED', is_confirmed = TRUE WHERE flag_id = 2;
UPDATE fraud_flags SET investigation_status = 'RESOLVED' WHERE flag_id = 3;

-- Update user risk scores based on their transaction history
CALL UpdateUserRiskScore(1);
CALL UpdateUserRiskScore(2);
CALL UpdateUserRiskScore(3);
CALL UpdateUserRiskScore(4);
CALL UpdateUserRiskScore(5);
CALL UpdateUserRiskScore(6);
CALL UpdateUserRiskScore(7);
CALL UpdateUserRiskScore(8);
CALL UpdateUserRiskScore(9);
CALL UpdateUserRiskScore(10);

-- Stored Procedure for User Login
DELIMITER $$
CREATE PROCEDURE UserLogin(
  IN p_email VARCHAR(255),
  IN p_password VARCHAR(255)
)
BEGIN
  -- This procedure checks if a user exists with the provided email and password.
  -- For security, passwords should be hashed. This is a simple example.
  SELECT user_id, username, email, account_status, risk_score
  FROM users
  WHERE email = p_email
    AND password = p_password;
END$$
DELIMITER ;

-- (Optional) Test the LAST_INSERT_ID() function:
SELECT LAST_INSERT_ID() AS transaction_id;

SHOW TABLES;

DESCRIBE users;
DESCRIBE merchants;
DESCRIBE transactions;
DESCRIBE fraud_rules;
DESCRIBE fraud_flags;

SHOW PROCEDURE STATUS WHERE Db = 'fraud_detection';

SELECT * FROM users;
SELECT * FROM merchants;
SELECT * FROM transactions;
SELECT * FROM fraud_rules;
SELECT * FROM fraud_flags;

CALL CreateTransaction(1, 1, 2345.00, 45.00045, -34.006, '#34r3f');
SELECT LAST_INSERT_ID() AS transaction_id;


SELECT * FROM transactions ORDER BY transaction_time DESC;

SELECT COUNT(*) AS total_fraud_flags
FROM fraud_flags;

SELECT rule_id, COUNT(*) AS fraud_count
FROM fraud_flags
GROUP BY rule_id;

SELECT fr.rule_name, COUNT(ff.flag_id) AS fraud_count
FROM fraud_flags ff
JOIN fraud_rules fr ON ff.rule_id = fr.rule_id
GROUP BY fr.rule_name;

SELECT investigation_status, COUNT(*) AS fraud_count
FROM fraud_flags
GROUP BY investigation_status;

SELECT flag_id, investigation_status, flagged_at
FROM fraud_flags
ORDER BY flagged_at DESC
LIMIT 10;

SELECT ff.flag_id,
       ff.flagged_at,
       ff.investigation_status,
       t.transaction_id,
       t.amount,
       t.transaction_time
FROM fraud_flags ff
JOIN transactions t ON ff.transaction_id = t.transaction_id
ORDER BY ff.flagged_at DESC;

SELECT t.user_id, COUNT(ff.flag_id) AS fraud_count
FROM fraud_flags ff
JOIN transactions t ON ff.transaction_id = t.transaction_id
GROUP BY t.user_id
ORDER BY fraud_count DESC;













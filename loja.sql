create database if not exists loja;

use loja;

CREATE TABLE grupos_usuarios (
  IDGrupo INT PRIMARY KEY AUTO_INCREMENT,
  NomeGrupo VARCHAR(60) NOT NULL UNIQUE,     -- 'GERENCIA', 'FUNCIONARIO', 'CLIENTE'...
  Descricao VARCHAR(255)
);

CREATE TABLE usuarios (
  IDUsuario INT PRIMARY KEY AUTO_INCREMENT,
  Nome VARCHAR(120) NOT NULL,
  IDGrupo INT NOT NULL,
  CriadoEm TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_usuario_grupo
    FOREIGN KEY (IDGrupo) REFERENCES grupos_usuarios(IDGrupo)
      ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE TABLE Clientes (
  IDCliente INT PRIMARY KEY AUTO_INCREMENT,
  Nome VARCHAR(120) NOT NULL,
  CPF CHAR(11) UNIQUE,
  CriadoEm TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE Funcionarios (
  IDFuncionario INT PRIMARY KEY AUTO_INCREMENT,
  Nome VARCHAR(120) NOT NULL,
  CPF CHAR(11) UNIQUE,
  Cargo VARCHAR(60),
  Salario DOUBLE,
  CriadoEm TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE Produtos (
  IDProduto INT PRIMARY KEY AUTO_INCREMENT,
  Nome VARCHAR(120) NOT NULL,
  Descricao TEXT,
  Preco DOUBLE NOT NULL,
  Estoque INT NOT NULL DEFAULT 0,
  CriadoEm TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE Vendas (
  IDVenda INT PRIMARY KEY AUTO_INCREMENT,
  IDCliente INT NOT NULL,
  IDFuncionario INT NOT NULL,
  DataVenda TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  Total DOUBLE NOT NULL DEFAULT 0,
  CONSTRAINT fk_venda_cliente
    FOREIGN KEY (IDCliente) REFERENCES Clientes(IDCliente)
      ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_venda_funcionario
    FOREIGN KEY (IDFuncionario) REFERENCES Funcionarios(IDFuncionario)
      ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE TABLE ItensVenda (
  IDItem INT PRIMARY KEY AUTO_INCREMENT,
  IDVenda INT NOT NULL,
  IDProduto INT NOT NULL,
  Quantidade INT NOT NULL,
  PrecoUnitario DOUBLE NOT NULL,
  CONSTRAINT fk_item_venda
    FOREIGN KEY (IDVenda) REFERENCES Vendas(IDVenda)
      ON DELETE CASCADE,
  CONSTRAINT fk_item_produto
    FOREIGN KEY (IDProduto) REFERENCES Produtos(IDProduto)
      ON DELETE RESTRICT
);

CREATE TABLE MovimentacoesEstoque ( 
  IDMovimentacao INT PRIMARY KEY AUTO_INCREMENT,
  IDProduto INT NOT NULL,
  TipoMovimentacao ENUM('Entrada', 'Saída') NOT NULL,
  Quantidade INT NOT NULL,
  DataMovimentacao TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (IDProduto) REFERENCES Produtos(IDProduto)
);

CREATE INDEX idx_clientes_nome      ON Clientes(Nome);
CREATE INDEX idx_funcionarios_nome  ON Funcionarios(Nome);
CREATE INDEX idx_produtos_nome      ON Produtos(Nome);
CREATE INDEX idx_vendas_data        ON Vendas(DataVenda);
CREATE INDEX idx_itens_venda_venda  ON ItensVenda(IDVenda);


DELIMITER //

-- 1) Retorna o estoque disponível do produto
CREATE FUNCTION fn_estoque_disponivel(p_IDProduto INT)
RETURNS INT
DETERMINISTIC
BEGIN
  DECLARE v INT;
  SELECT Estoque INTO v FROM Produtos WHERE IDProduto = p_IDProduto;
  RETURN IFNULL(v, 0);
END//

-- 2) Calcula o total teórico da venda (soma de itens)
CREATE FUNCTION fn_total_venda(p_IDVenda INT)
RETURNS DOUBLE
DETERMINISTIC
BEGIN
  DECLARE v_total DOUBLE;
  SELECT IFNULL(SUM(Quantidade * PrecoUnitario),0)
    INTO v_total
    FROM ItensVenda
    WHERE IDVenda = p_IDVenda;
  RETURN v_total;
END//

-- 3) Aplica desconto percentual (com limites de 0 a 90%)
CREATE FUNCTION fn_preco_com_desconto(p_preco DOUBLE, p_pct DOUBLE)
RETURNS DOUBLE
DETERMINISTIC
BEGIN
  IF p_pct < 0 THEN SET p_pct = 0; END IF;
  IF p_pct > 90 THEN SET p_pct = 90; END IF;
  RETURN ROUND(p_preco * (1 - p_pct/100), 2);
END//

DELIMITER ;

-- TRIGGERS (estoque)[

DELIMITER //

-- BEFORE: valida estoque e define preço se vier 0

CREATE TRIGGER trg_itensvenda_before_insert
BEFORE INSERT ON ItensVenda
FOR EACH ROW
BEGIN
  DECLARE v_estoque INT;
  DECLARE v_preco DOUBLE;

  SELECT Estoque, Preco INTO v_estoque, v_preco
  FROM Produtos
  WHERE IDProduto = NEW.IDProduto
  FOR UPDATE;

  IF v_estoque IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Produto inexistente.';
  END IF;

  IF NEW.Quantidade > v_estoque THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Estoque insuficiente.';
  END IF;

  IF NEW.PrecoUnitario IS NULL OR NEW.PrecoUnitario = 0 THEN
    SET NEW.PrecoUnitario = v_preco;
  END IF;
END//

-- AFTER: baixa estoque e conta saída

CREATE TRIGGER trg_itensvenda_after_insert
AFTER INSERT ON ItensVenda
FOR EACH ROW
BEGIN
  UPDATE Produtos
  SET Estoque = Estoque - NEW.Quantidade
  WHERE IDProduto = NEW.IDProduto;

  INSERT INTO MovimentacoesEstoque (IDProduto, TipoMovimentacao, Quantidade)
  VALUES (NEW.IDProduto, 'Saída', NEW.Quantidade);
END//

DELIMITER ;

-- PROCEDURES

DELIMITER //

-- 1 Ajuste manual de estoque (entrada/saída)
CREATE PROCEDURE sp_ajustar_estoque (
  IN p_IDProduto INT,
  IN p_Tipo ENUM('Entrada','Saída'),
  IN p_Quantidade INT
)
BEGIN
  IF p_Tipo = 'Entrada' THEN
    UPDATE Produtos SET Estoque = Estoque + p_Quantidade
    WHERE IDProduto = p_IDProduto;

    INSERT INTO MovimentacoesEstoque (IDProduto, TipoMovimentacao, Quantidade)
    VALUES (p_IDProduto, 'Entrada', p_Quantidade);

  ELSEIF p_Tipo = 'Saída' THEN
    IF fn_estoque_disponivel(p_IDProduto) < p_Quantidade THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Estoque insuficiente para saída manual.';
    END IF;

    UPDATE Produtos SET Estoque = Estoque - p_Quantidade
    WHERE IDProduto = p_IDProduto;

    INSERT INTO MovimentacoesEstoque (IDProduto, TipoMovimentacao, Quantidade)
    VALUES (p_IDProduto, 'Saída', p_Quantidade);

  ELSE
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'TipoMovimentacao inválido. Use Entrada ou Saída.';
  END IF;
END//

-- 2 Cria a venda (retorna ID gerado via SELECT)
CREATE PROCEDURE sp_criar_venda (
  IN  p_IDCliente INT,
  IN  p_IDFuncionario INT
)
BEGIN
  INSERT INTO Vendas (IDCliente, IDFuncionario, Total)
  VALUES (p_IDCliente, p_IDFuncionario, 0);

  SELECT LAST_INSERT_ID() AS IDVenda;
END//

-- 3 Adiciona item à venda; usa preço do produto se passar 0; atualiza Total
CREATE PROCEDURE sp_adicionar_item_venda (
  IN p_IDVenda INT,
  IN p_IDProduto INT,
  IN p_Quantidade INT,
  IN p_PrecoUnitario DOUBLE
)
BEGIN
  DECLARE v_preco DOUBLE;

  IF p_PrecoUnitario IS NULL OR p_PrecoUnitario <= 0 THEN
    SELECT Preco INTO v_preco FROM Produtos WHERE IDProduto = p_IDProduto;
  ELSE
    SET v_preco = p_PrecoUnitario;
  END IF;

  INSERT INTO ItensVenda (IDVenda, IDProduto, Quantidade, PrecoUnitario)
  VALUES (p_IDVenda, p_IDProduto, p_Quantidade, v_preco);

  -- Atualiza Total incrementalmente
  UPDATE Vendas
  SET Total = Total + (p_Quantidade * v_preco)
  WHERE IDVenda = p_IDVenda;
END//

-- 4 Recalcula Total a partir dos itens usando a FUNCTION
CREATE PROCEDURE sp_recalcular_total_venda (
  IN p_IDVenda INT
)
BEGIN
  UPDATE Vendas
  SET Total = fn_total_venda(p_IDVenda)
  WHERE IDVenda = p_IDVenda;
END//

DELIMITER ;

-- Views de acesso (cliente e funcionário)

CREATE VIEW v_produtos_cliente AS
SELECT IDProduto, Nome, Preco, Estoque
FROM Produtos;

CREATE VIEW v_produtos_funcionario AS
SELECT IDProduto, Nome, Preco, Estoque
FROM Produtos;

CREATE USER gerencia@localhost IDENTIFIED BY 'gerencia';
CREATE USER funcionario@localhost IDENTIFIED BY 'funcionario';
CREATE USER cliente@localhost IDENTIFIED BY 'cliente';

grant all on loja.* to gerencia@localhost;
grant select on loja.v_produtos_funcionario TO funcionario@localhost ;
grant select on loja.Clientes TO funcionario@localhost;
grant select on loja.Funcionarios TO funcionario@localhost;
grant select , INSERT, UPDATE, DELETE ON loja.Vendas    TO funcionario@localhost;
grant select , INSERT, UPDATE, DELETE ON loja.ItensVenda TO funcionario@localhost;
grant select on loja.v_produtos_cliente TO cliente@localhost;


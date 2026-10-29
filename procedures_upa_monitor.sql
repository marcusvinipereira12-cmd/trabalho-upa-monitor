/*
TRABALHO ACADÊMICO — UPA MONITOR DE PORTO VELHO
SQL Server — Procedures e dados fictícios de teste

IMPORTANTE:
- Este é um modelo proposto, não o esquema interno confirmado do portal.
- Não contém dados oficiais. Os registros de demonstração são fictícios.
- Executar apenas em banco de desenvolvimento/teste.
- Execute primeiro o bloco de criação de tabelas, depois as procedures
  e por último os INSERTs e chamadas de teste.
*/

-- =========================================================
-- 1. ESTRUTURA MÍNIMA DE TESTE
-- Se as tabelas já existirem, não execute novamente este bloco.
-- =========================================================
CREATE TABLE dbo.UPA
(
    id_upa INT PRIMARY KEY,
    nome VARCHAR(120) NOT NULL UNIQUE,
    status VARCHAR(20) NOT NULL
);

CREATE TABLE dbo.SETOR
(
    id_setor INT PRIMARY KEY,
    id_upa INT NOT NULL,
    nome VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL,
    CONSTRAINT FK_SETOR_UPA
        FOREIGN KEY (id_upa) REFERENCES dbo.UPA(id_upa)
);

CREATE TABLE dbo.FILA
(
    id_fila INT PRIMARY KEY,
    id_setor INT NOT NULL,
    nome VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL,
    CONSTRAINT FK_FILA_SETOR
        FOREIGN KEY (id_setor) REFERENCES dbo.SETOR(id_setor)
);

CREATE TABLE dbo.CLASSIFICACAO_RISCO
(
    id_classificacao INT PRIMARY KEY,
    nome VARCHAR(50) NOT NULL UNIQUE,
    ordem_prioridade INT NOT NULL
);

CREATE TABLE dbo.ATENDIMENTO
(
    id_atendimento INT PRIMARY KEY,
    id_setor INT NOT NULL,
    id_classificacao INT NOT NULL,
    data_entrada DATETIME2(0) NOT NULL,
    data_inicio_atendimento DATETIME2(0) NULL,
    status VARCHAR(30) NOT NULL,
    CONSTRAINT FK_ATENDIMENTO_SETOR
        FOREIGN KEY (id_setor) REFERENCES dbo.SETOR(id_setor),
    CONSTRAINT FK_ATENDIMENTO_RISCO
        FOREIGN KEY (id_classificacao)
        REFERENCES dbo.CLASSIFICACAO_RISCO(id_classificacao)
);

CREATE TABLE dbo.MONITORAMENTO
(
    id_monitoramento INT PRIMARY KEY,
    id_upa INT NOT NULL,
    data_referencia DATE NOT NULL,
    hora_referencia TIME(0) NOT NULL,
    CONSTRAINT FK_MONITORAMENTO_UPA
        FOREIGN KEY (id_upa) REFERENCES dbo.UPA(id_upa)
);

CREATE TABLE dbo.MEDICAO
(
    id_medicao INT PRIMARY KEY,
    id_monitoramento INT NOT NULL,
    id_setor INT NOT NULL,
    pacientes_aguardando INT NOT NULL,
    casos_criticos INT NOT NULL,
    total_atendimentos INT NOT NULL,
    espera_media_minutos DECIMAL(10,2) NULL,
    espera_maxima_minutos DECIMAL(10,2) NULL,
    CONSTRAINT FK_MEDICAO_MONITORAMENTO
        FOREIGN KEY (id_monitoramento)
        REFERENCES dbo.MONITORAMENTO(id_monitoramento),
    CONSTRAINT FK_MEDICAO_SETOR
        FOREIGN KEY (id_setor) REFERENCES dbo.SETOR(id_setor),
    CONSTRAINT CK_MEDICAO_CONTAGENS CHECK
    (
        pacientes_aguardando >= 0
        AND casos_criticos >= 0
        AND total_atendimentos >= 0
    ),
    CONSTRAINT CK_MEDICAO_TEMPOS CHECK
    (
        (espera_media_minutos IS NULL OR espera_media_minutos >= 0)
        AND (espera_maxima_minutos IS NULL OR espera_maxima_minutos >= 0)
    )
);
GO

-- =========================================================
-- 2. PROCEDURE: QUADRO DE FILAS
-- Retorna a captura mais recente por UPA/setor.
-- =========================================================
CREATE OR ALTER PROCEDURE dbo.sp_quadro_de_filas
    @data_referencia DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /*
      @data_referencia NULL: usa a última captura disponível.
      Data informada: considera apenas capturas daquele dia.
      Não soma snapshots: uma mesma fila/pessoa pode aparecer
      em várias capturas ao longo do tempo.
    */
    ;WITH Capturas AS
    (
        SELECT
            u.id_upa,
            u.nome AS upa,
            s.id_setor,
            s.nome AS setor,
            m.id_monitoramento,
            m.data_referencia,
            m.hora_referencia,
            md.id_medicao,
            md.pacientes_aguardando,
            md.casos_criticos,
            md.total_atendimentos,
            md.espera_media_minutos,
            md.espera_maxima_minutos,
            ROW_NUMBER() OVER
            (
                PARTITION BY u.id_upa, s.id_setor
                ORDER BY
                    m.data_referencia DESC,
                    m.hora_referencia DESC,
                    m.id_monitoramento DESC,
                    md.id_medicao DESC
            ) AS rn
        FROM dbo.UPA AS u
        INNER JOIN dbo.SETOR AS s
            ON s.id_upa = u.id_upa
        INNER JOIN dbo.MONITORAMENTO AS m
            ON m.id_upa = u.id_upa
        INNER JOIN dbo.MEDICAO AS md
            ON md.id_monitoramento = m.id_monitoramento
           AND md.id_setor = s.id_setor
        WHERE @data_referencia IS NULL
           OR m.data_referencia = @data_referencia
    )
    SELECT
        id_upa, upa, id_setor, setor,
        data_referencia, hora_referencia,
        pacientes_aguardando, casos_criticos,
        total_atendimentos, espera_media_minutos,
        espera_maxima_minutos
    FROM Capturas
    WHERE rn = 1
    ORDER BY upa, setor;
END;
GO

-- =========================================================
-- 3. PROCEDURE: ATLAS E CUBOS
-- Indicadores agregados por UPA/setor dentro do período.
-- =========================================================
CREATE OR ALTER PROCEDURE dbo.sp_atlas_e_cubos
    @data_inicial DATE,
    @data_final DATE
AS
BEGIN
    SET NOCOUNT ON;

    IF @data_inicial IS NULL OR @data_final IS NULL
       OR @data_inicial > @data_final
    BEGIN
        THROW 50001, 'Informe um intervalo de datas válido.', 1;
    END;

    /*
      - O intervalo inclui as duas datas.
      - A média calculada é a média dos valores de espera média
        registrados por captura; não é necessariamente a média
        ponderada por paciente.
      - O maior tempo é o máximo dos valores registrados.
      - Contagens de aguardando/atendimentos vêm da última captura,
        não da soma dos snapshots.
      - Casos críticos máximos é o maior número registrado em uma
        captura; não significa número de pessoas únicas no período.
    */
    ;WITH Base AS
    (
        SELECT
            u.id_upa,
            u.nome AS upa,
            s.id_setor,
            s.nome AS setor,
            m.id_monitoramento,
            m.data_referencia,
            m.hora_referencia,
            md.id_medicao,
            md.pacientes_aguardando,
            md.casos_criticos,
            md.total_atendimentos,
            md.espera_media_minutos,
            md.espera_maxima_minutos
        FROM dbo.UPA AS u
        INNER JOIN dbo.SETOR AS s
            ON s.id_upa = u.id_upa
        INNER JOIN dbo.MONITORAMENTO AS m
            ON m.id_upa = u.id_upa
        INNER JOIN dbo.MEDICAO AS md
            ON md.id_monitoramento = m.id_monitoramento
           AND md.id_setor = s.id_setor
        WHERE m.data_referencia >= @data_inicial
          AND m.data_referencia < DATEADD(DAY, 1, @data_final)
    ),
    Ordenada AS
    (
        SELECT *,
            ROW_NUMBER() OVER
            (
                PARTITION BY id_upa, id_setor
                ORDER BY
                    data_referencia DESC,
                    hora_referencia DESC,
                    id_monitoramento DESC,
                    id_medicao DESC
            ) AS rn
        FROM Base
    ),
    Agregada AS
    (
        SELECT
            id_upa, upa, id_setor, setor,
            COUNT_BIG(*) AS quantidade_capturas,
            AVG(espera_media_minutos)
                AS media_das_esperas_registradas,
            MAX(espera_maxima_minutos)
                AS maior_espera_registrada,
            MAX(casos_criticos)
                AS maior_contagem_criticos_registrada
        FROM Base
        GROUP BY id_upa, upa, id_setor, setor
    )
    SELECT
        a.id_upa, a.upa, a.id_setor, a.setor,
        a.quantidade_capturas,
        a.media_das_esperas_registradas,
        a.maior_espera_registrada,
        a.maior_contagem_criticos_registrada,
        u.data_referencia AS data_ultima_captura,
        u.hora_referencia AS hora_ultima_captura,
        u.pacientes_aguardando AS aguardando_na_ultima_captura,
        u.total_atendimentos AS atendimentos_na_ultima_captura
    FROM Agregada AS a
    INNER JOIN Ordenada AS u
        ON u.id_upa = a.id_upa
       AND u.id_setor = a.id_setor
       AND u.rn = 1
    ORDER BY a.upa, a.setor;
END;
GO

-- =========================================================
-- 4. DADOS DE TESTE — FICTÍCIOS, NÃO OFICIAIS
-- =========================================================
INSERT INTO dbo.UPA (id_upa, nome, status)
VALUES (1, 'UPA EXEMPLO - FICTÍCIA', 'ONLINE');

INSERT INTO dbo.SETOR (id_setor, id_upa, nome, status)
VALUES (1, 1, 'SETOR EXEMPLO', 'ATIVO');

INSERT INTO dbo.FILA (id_fila, id_setor, nome, status)
VALUES (1, 1, 'FILA EXEMPLO', 'ATIVA');

INSERT INTO dbo.CLASSIFICACAO_RISCO
    (id_classificacao, nome, ordem_prioridade)
VALUES (1, 'RISCO EXEMPLO A', 1),
       (2, 'RISCO EXEMPLO B', 2);

INSERT INTO dbo.MONITORAMENTO
    (id_monitoramento, id_upa, data_referencia, hora_referencia)
VALUES (1, 1, '2026-10-28', '10:00:00'),
       (2, 1, '2026-10-28', '11:00:00');

INSERT INTO dbo.MEDICAO
    (id_medicao, id_monitoramento, id_setor,
     pacientes_aguardando, casos_criticos, total_atendimentos,
     espera_media_minutos, espera_maxima_minutos)
VALUES (1, 1, 1, 10, 2, 40, 30.00, 70.00),
       (2, 2, 1,  8, 1, 45, 25.00, 60.00);
GO

-- =========================================================
-- 5. EXECUÇÃO DE TESTE
-- =========================================================
EXEC dbo.sp_quadro_de_filas;

EXEC dbo.sp_atlas_e_cubos
    @data_inicial = '2026-10-28',
    @data_final = '2026-10-28';
GO

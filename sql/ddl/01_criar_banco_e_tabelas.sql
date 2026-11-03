-- =====================================================================
-- Code e Corte — Projeto Integrador de Modelagem de Dados (entrega final)
-- DDL: banco, tabelas, chaves, restrições, regras automáticas e views
--
-- SGBD ....: PostgreSQL 14 ou superior
-- Execução : psql -U postgres -f 01_criar_banco_e_tabelas.sql
--            (o script cria o banco code_e_corte e conecta nele)
-- Para recriar do zero, rode antes:  DROP DATABASE IF EXISTS code_e_corte;
--
-- Convenções: tabelas e colunas em snake_case, sem acentos; PK = id_<tabela>;
-- subtipos de USUARIO usam como PK a própria FK para usuario.
-- Os comentários citam a regra de negócio protegida em linguagem corrente;
-- a numeração RN/RF dos documentos do grupo ainda será unificada.
-- =====================================================================

CREATE DATABASE code_e_corte;
\connect code_e_corte

-- btree_gist permite restrições de exclusão que combinam igualdade e
-- sobreposição de intervalos (conflito de agenda, lotação e vigência).
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- =====================================================================
-- 1. PESSOAS — USUARIO e sua especialização parcial e sobreposta
-- =====================================================================

CREATE TABLE usuario (
    id_usuario     SERIAL       PRIMARY KEY,
    nome           VARCHAR(100) NOT NULL,
    email          VARCHAR(100) NOT NULL,
    telefone       VARCHAR(20),
    senha_hash     VARCHAR(255) NOT NULL,           -- nunca a senha em texto
    data_cadastro  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ativo          BOOLEAN      NOT NULL DEFAULT TRUE,   -- desativa, não apaga
    CONSTRAINT uq_usuario_email UNIQUE (email),
    CONSTRAINT ck_usuario_email CHECK (email LIKE '%_@_%._%')
);

CREATE TABLE cliente (
    id_cliente       INTEGER PRIMARY KEY,
    data_nascimento  DATE,
    CONSTRAINT fk_cliente_usuario FOREIGN KEY (id_cliente)
        REFERENCES usuario (id_usuario) ON DELETE CASCADE,
    CONSTRAINT ck_cliente_nascimento CHECK (data_nascimento >= DATE '1900-01-01')
);

CREATE TABLE funcionario (
    id_funcionario  INTEGER      PRIMARY KEY,
    cpf             CHAR(11)     NOT NULL,
    especialidade   VARCHAR(60)  NOT NULL,
    data_admissao   DATE         NOT NULL,
    ativo           BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT fk_funcionario_usuario FOREIGN KEY (id_funcionario)
        REFERENCES usuario (id_usuario) ON DELETE CASCADE,
    CONSTRAINT uq_funcionario_cpf UNIQUE (cpf),
    CONSTRAINT ck_funcionario_cpf CHECK (cpf ~ '^[0-9]{11}$')
);

-- "dono" do salão: perfil que responde pelo CNPJ e contrata o plano
CREATE TABLE conta_profissional (
    id_profissional  INTEGER   PRIMARY KEY,
    cnpj             CHAR(14)  NOT NULL,
    CONSTRAINT fk_conta_prof_usuario FOREIGN KEY (id_profissional)
        REFERENCES usuario (id_usuario) ON DELETE CASCADE,
    CONSTRAINT uq_conta_prof_cnpj UNIQUE (cnpj),
    CONSTRAINT ck_conta_prof_cnpj CHECK (cnpj ~ '^[0-9]{14}$')
);


-- =====================================================================
-- 2. UNIDADE (SALAO), HORÁRIOS E LOTAÇÃO DO FUNCIONÁRIO
-- =====================================================================

CREATE TABLE salao (
    id_salao         SERIAL        PRIMARY KEY,
    id_profissional  INTEGER       NOT NULL,         -- toda unidade tem um dono
    nome             VARCHAR(100)  NOT NULL,
    cnpj             CHAR(14)      NOT NULL,
    telefone         VARCHAR(20),
    -- endereço (atributo composto do DER vira colunas simples)
    cep              CHAR(8)       NOT NULL,
    logradouro       VARCHAR(120)  NOT NULL,
    numero           VARCHAR(10)   NOT NULL,
    bairro           VARCHAR(60)   NOT NULL,
    cidade           VARCHAR(60)   NOT NULL,
    uf               CHAR(2)       NOT NULL,
    -- localização (composto): usada na busca por proximidade
    latitude         NUMERIC(9,6),
    longitude        NUMERIC(9,6),
    ativo            BOOLEAN       NOT NULL DEFAULT TRUE,
    suspenso         BOOLEAN       NOT NULL DEFAULT FALSE,  -- suspensa por inadimplência (novos agendamentos)
    CONSTRAINT fk_salao_profissional FOREIGN KEY (id_profissional)
        REFERENCES conta_profissional (id_profissional),
    CONSTRAINT uq_salao_cnpj UNIQUE (cnpj),
    CONSTRAINT ck_salao_cnpj CHECK (cnpj ~ '^[0-9]{14}$'),
    CONSTRAINT ck_salao_cep  CHECK (cep ~ '^[0-9]{8}$'),
    CONSTRAINT ck_salao_uf   CHECK (uf ~ '^[A-Z]{2}$'),
    CONSTRAINT ck_salao_latitude  CHECK (latitude  BETWEEN -90  AND 90),
    CONSTRAINT ck_salao_longitude CHECK (longitude BETWEEN -180 AND 180),
    CONSTRAINT ck_salao_coordenadas CHECK ((latitude IS NULL) = (longitude IS NULL))
);

-- Entidade fraca de SALAO: identificada por (id_salao, dia_semana).
-- A PK já garante no máximo 7 linhas por unidade; o mínimo de 1 dia
-- (cardinalidade 1,7 do DER) é verificado na aplicação ao cadastrar a unidade.
CREATE TABLE horario_funcionamento (
    id_salao         INTEGER   NOT NULL,
    dia_semana       SMALLINT  NOT NULL,             -- 0 = domingo ... 6 = sábado
    hora_abertura    TIME      NOT NULL,
    hora_fechamento  TIME      NOT NULL,
    CONSTRAINT pk_horario_funcionamento PRIMARY KEY (id_salao, dia_semana),
    CONSTRAINT fk_horario_salao FOREIGN KEY (id_salao)
        REFERENCES salao (id_salao) ON DELETE CASCADE,
    CONSTRAINT ck_horario_dia  CHECK (dia_semana BETWEEN 0 AND 6),
    CONSTRAINT ck_horario_hora CHECK (hora_abertura < hora_fechamento)
);

-- Relacionamento "trabalha em" com histórico: cada linha é um período em que o
-- funcionário atuou em uma unidade. Transferência = fechar a lotação atual
-- (data_fim) e abrir outra.
CREATE TABLE lotacao (
    id_lotacao      SERIAL   PRIMARY KEY,
    id_funcionario  INTEGER  NOT NULL,
    id_salao        INTEGER  NOT NULL,
    data_inicio     DATE     NOT NULL,
    data_fim        DATE,                            -- NULL = lotação em vigor
    CONSTRAINT fk_lotacao_funcionario FOREIGN KEY (id_funcionario)
        REFERENCES funcionario (id_funcionario),
    CONSTRAINT fk_lotacao_salao FOREIGN KEY (id_salao)
        REFERENCES salao (id_salao),
    CONSTRAINT ck_lotacao_periodo CHECK (data_fim IS NULL OR data_fim >= data_inicio),
    -- um funcionário não pode estar em duas unidades ao mesmo tempo
    CONSTRAINT ex_lotacao_sem_sobreposicao EXCLUDE USING gist (
        id_funcionario WITH =,
        daterange(data_inicio, data_fim, '[]') WITH &&
    )
);


-- =====================================================================
-- 3. SERVIÇOS E AGENDA
-- =====================================================================

-- O serviço pertence ao funcionário, que define preço e duração.
CREATE TABLE servico (
    id_servico      SERIAL         PRIMARY KEY,
    id_funcionario  INTEGER        NOT NULL,
    nome            VARCHAR(100)   NOT NULL,
    descricao       TEXT,
    preco           NUMERIC(10,2)  NOT NULL,
    duracao_min     INTEGER        NOT NULL,
    ativo           BOOLEAN        NOT NULL DEFAULT TRUE,
    CONSTRAINT fk_servico_funcionario FOREIGN KEY (id_funcionario)
        REFERENCES funcionario (id_funcionario),
    CONSTRAINT ck_servico_preco    CHECK (preco > 0),
    CONSTRAINT ck_servico_duracao  CHECK (duracao_min > 0)
);

-- O agendamento aponta para a LOTAÇÃO, que já identifica funcionário E unidade.
-- Assim o histórico de transferências não muda onde o atendimento aconteceu.
CREATE TABLE agendamento (
    id_agendamento    SERIAL       PRIMARY KEY,
    id_cliente        INTEGER      NOT NULL,
    id_lotacao        INTEGER      NOT NULL,
    data_hora_inicio  TIMESTAMP    NOT NULL,
    data_hora_fim     TIMESTAMP    NOT NULL,         -- início + soma das durações
    status            VARCHAR(20)  NOT NULL DEFAULT 'agendado',
    observacao        TEXT,
    criado_em         TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_agendamento_cliente FOREIGN KEY (id_cliente)
        REFERENCES cliente (id_cliente),
    CONSTRAINT fk_agendamento_lotacao FOREIGN KEY (id_lotacao)
        REFERENCES lotacao (id_lotacao),
    CONSTRAINT ck_agendamento_periodo CHECK (data_hora_fim > data_hora_inicio),
    CONSTRAINT ck_agendamento_status  CHECK (status IN
        ('agendado', 'confirmado', 'concluido', 'cancelado', 'nao_compareceu')),
    -- no banco: dois pedidos simultâneos para o mesmo horário do mesmo
    -- funcionário não passam, mesmo com concorrência.
    CONSTRAINT ex_agendamento_sem_conflito EXCLUDE USING gist (
        id_lotacao WITH =,
        tsrange(data_hora_inicio, data_hora_fim) WITH &&
    ) WHERE (status <> 'cancelado')
);

-- Relacionamento N:N "contém", com os valores praticados no momento da marcação.
CREATE TABLE item_agendamento (
    id_agendamento  INTEGER        NOT NULL,
    id_servico      INTEGER        NOT NULL,
    preco_cobrado   NUMERIC(10,2)  NOT NULL,
    duracao_min     INTEGER        NOT NULL,
    CONSTRAINT pk_item_agendamento PRIMARY KEY (id_agendamento, id_servico),
    CONSTRAINT fk_item_agendamento FOREIGN KEY (id_agendamento)
        REFERENCES agendamento (id_agendamento) ON DELETE CASCADE,
    CONSTRAINT fk_item_servico FOREIGN KEY (id_servico)
        REFERENCES servico (id_servico),
    CONSTRAINT ck_item_preco   CHECK (preco_cobrado >= 0),
    CONSTRAINT ck_item_duracao CHECK (duracao_min > 0)
);


-- =====================================================================
-- 4. PAGAMENTO, AVALIAÇÃO E FAVORITOS
-- =====================================================================

-- Cada linha é uma TENTATIVA de pagamento: recusadas, parciais e a que quita.
-- O total a pagar não é guardado aqui: é a soma de preco_cobrado dos itens.
CREATE TABLE pagamento (
    id_pagamento     SERIAL         PRIMARY KEY,
    id_agendamento   INTEGER        NOT NULL,
    valor            NUMERIC(10,2)  NOT NULL,          -- valor desta tentativa
    forma_pagamento  VARCHAR(10)    NOT NULL,
    status           VARCHAR(10)    NOT NULL DEFAULT 'pendente',
    data_tentativa   TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    data_aprovacao   TIMESTAMP,                        -- só se aprovado
    motivo_recusa    VARCHAR(100),                     -- só se recusado
    CONSTRAINT fk_pagamento_agendamento FOREIGN KEY (id_agendamento)
        REFERENCES agendamento (id_agendamento),
    CONSTRAINT ck_pagamento_valor  CHECK (valor > 0),
    CONSTRAINT ck_pagamento_forma  CHECK (forma_pagamento IN
        ('dinheiro', 'pix', 'debito', 'credito')),
    CONSTRAINT ck_pagamento_status CHECK (status IN
        ('pendente', 'aprovado', 'recusado', 'estornado')),
    CONSTRAINT ck_pagamento_aprovacao CHECK (status <> 'aprovado' OR data_aprovacao IS NOT NULL),
    CONSTRAINT ck_pagamento_motivo    CHECK (motivo_recusa IS NULL OR status = 'recusado')
);

CREATE TABLE avaliacao (
    id_avaliacao    SERIAL       PRIMARY KEY,
    id_agendamento  INTEGER      NOT NULL,
    nota            SMALLINT     NOT NULL,
    comentario      TEXT,
    data_avaliacao  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_avaliacao_agendamento FOREIGN KEY (id_agendamento)
        REFERENCES agendamento (id_agendamento),
    CONSTRAINT uq_avaliacao_agendamento UNIQUE (id_agendamento),
    CONSTRAINT ck_avaliacao_nota CHECK (nota BETWEEN 1 AND 5)
);

-- Relacionamento N:N "favorita"
CREATE TABLE favorito (
    id_cliente       INTEGER    NOT NULL,
    id_salao         INTEGER    NOT NULL,
    data_favoritado  TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_favorito PRIMARY KEY (id_cliente, id_salao),
    CONSTRAINT fk_favorito_cliente FOREIGN KEY (id_cliente)
        REFERENCES cliente (id_cliente) ON DELETE CASCADE,
    CONSTRAINT fk_favorito_salao FOREIGN KEY (id_salao)
        REFERENCES salao (id_salao) ON DELETE CASCADE
);


-- =====================================================================
-- 5. PLANOS E MENSALIDADE DA PLATAFORMA (dono paga a Code e Corte)
--    Cobrança mensal; limite de atendimentos controlado por semana.
-- =====================================================================

CREATE TABLE plano (
    id_plano        SERIAL         PRIMARY KEY,
    nome            VARCHAR(30)    NOT NULL,
    preco           NUMERIC(10,2)  NOT NULL,          -- por mês
    limite_semanal  INTEGER,                          -- NULL = sem limite
    ilimitado       BOOLEAN        NOT NULL DEFAULT FALSE,
    ativo           BOOLEAN        NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_plano_nome UNIQUE (nome),
    CONSTRAINT ck_plano_preco  CHECK (preco > 0),
    CONSTRAINT ck_plano_limite CHECK (limite_semanal IS NULL OR limite_semanal > 0),
    CONSTRAINT ck_plano_ilimitado CHECK (ilimitado = (limite_semanal IS NULL))
);

-- Plano contratado pelo dono. Um dono tem no máximo uma assinatura ativa.
CREATE TABLE assinatura (
    id_assinatura   SERIAL      PRIMARY KEY,
    id_profissional INTEGER     NOT NULL,
    id_plano        INTEGER     NOT NULL,
    data_inicio     DATE        NOT NULL,
    data_renovacao  DATE        NOT NULL,             -- próxima cobrança mensal
    data_fim        DATE,
    status          VARCHAR(10) NOT NULL DEFAULT 'ativa',
    CONSTRAINT fk_assinatura_profissional FOREIGN KEY (id_profissional)
        REFERENCES conta_profissional (id_profissional),
    CONSTRAINT fk_assinatura_plano FOREIGN KEY (id_plano)
        REFERENCES plano (id_plano),
    CONSTRAINT ck_assinatura_status  CHECK (status IN ('ativa', 'cancelada')),
    CONSTRAINT ck_assinatura_renovacao CHECK (data_renovacao > data_inicio),
    CONSTRAINT ck_assinatura_fim     CHECK (data_fim IS NULL OR data_fim >= data_inicio)
);
CREATE UNIQUE INDEX uq_assinatura_ativa ON assinatura (id_profissional) WHERE status = 'ativa';

-- Mudanças de plano ao longo do tempo (preenchida por gatilho).
CREATE TABLE historico_assinatura (
    id_historico       SERIAL         PRIMARY KEY,
    id_assinatura      INTEGER        NOT NULL,
    id_plano_anterior  INTEGER,
    id_plano_novo      INTEGER        NOT NULL,
    tipo               VARCHAR(15)    NOT NULL,
    valor_diferenca    NUMERIC(10,2),                  -- upgrade: diferença proporcional aos dias restantes
    data_alteracao     TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_hist_assinatura FOREIGN KEY (id_assinatura)
        REFERENCES assinatura (id_assinatura),
    CONSTRAINT fk_hist_plano_anterior FOREIGN KEY (id_plano_anterior)
        REFERENCES plano (id_plano),
    CONSTRAINT fk_hist_plano_novo FOREIGN KEY (id_plano_novo)
        REFERENCES plano (id_plano),
    CONSTRAINT ck_hist_tipo CHECK (tipo IN ('contratacao', 'upgrade', 'downgrade', 'cancelamento'))
);

-- Uma linha por semana (segunda 00:00 a domingo 23:59). Guarda a "fotografia"
-- do fechamento: plano e limite aplicáveis, quantidade apurada e data.
-- Depois de fechada, a linha não muda: correções vão para ajuste_mensalidade.
CREATE TABLE ciclo_semanal (
    id_ciclo          SERIAL       PRIMARY KEY,
    id_assinatura     INTEGER      NOT NULL,
    id_plano          INTEGER      NOT NULL,
    semana_inicio     DATE         NOT NULL,           -- sempre uma segunda-feira
    semana_fim        DATE         NOT NULL,           -- domingo
    limite_aplicavel  INTEGER,                         -- NULL = sem limite
    qtd_apurada       INTEGER,                         -- preenchida no fechamento
    status            VARCHAR(10)  NOT NULL DEFAULT 'aberto',
    data_fechamento   TIMESTAMP,
    CONSTRAINT fk_ciclo_assinatura FOREIGN KEY (id_assinatura)
        REFERENCES assinatura (id_assinatura),
    CONSTRAINT fk_ciclo_plano FOREIGN KEY (id_plano)
        REFERENCES plano (id_plano),
    CONSTRAINT uq_ciclo_semana UNIQUE (id_assinatura, semana_inicio),
    CONSTRAINT ck_ciclo_segunda CHECK (EXTRACT(ISODOW FROM semana_inicio) = 1),
    CONSTRAINT ck_ciclo_fim     CHECK (semana_fim = semana_inicio + 6),
    CONSTRAINT ck_ciclo_status  CHECK (status IN ('aberto', 'fechado')),
    CONSTRAINT ck_ciclo_fechado CHECK (status = 'aberto'
        OR (qtd_apurada IS NOT NULL AND data_fechamento IS NOT NULL))
);

-- Correção posterior ao fechamento: nunca apaga o dado original.
CREATE TABLE ajuste_mensalidade (
    id_ajuste            SERIAL       PRIMARY KEY,
    id_ciclo             INTEGER      NOT NULL,
    id_agendamento       INTEGER,                      -- atendimento afetado, quando houver
    tipo                 VARCHAR(10)  NOT NULL,
    quantidade_anterior  INTEGER      NOT NULL,
    quantidade_corrigida INTEGER      NOT NULL,
    justificativa        TEXT         NOT NULL,
    id_responsavel       INTEGER      NOT NULL,
    data_ajuste          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_ajuste_ciclo FOREIGN KEY (id_ciclo)
        REFERENCES ciclo_semanal (id_ciclo),
    CONSTRAINT fk_ajuste_agendamento FOREIGN KEY (id_agendamento)
        REFERENCES agendamento (id_agendamento),
    CONSTRAINT fk_ajuste_responsavel FOREIGN KEY (id_responsavel)
        REFERENCES usuario (id_usuario),
    CONSTRAINT ck_ajuste_tipo CHECK (tipo IN ('inclusao', 'exclusao', 'correcao')),
    CONSTRAINT ck_ajuste_qtd  CHECK (quantidade_anterior >= 0 AND quantidade_corrigida >= 0),
    CONSTRAINT ck_ajuste_justificativa CHECK (length(trim(justificativa)) > 0)
);

-- Cobrança mensal da assinatura. O valor do plano é copiado na geração, então
-- reajuste de preço não muda cobranças passadas.
CREATE TABLE mensalidade (
    id_mensalidade   SERIAL         PRIMARY KEY,
    id_assinatura    INTEGER        NOT NULL,
    ciclo_inicio     DATE           NOT NULL,
    ciclo_fim        DATE           NOT NULL,
    valor_plano      NUMERIC(10,2)  NOT NULL,
    valor_upgrade    NUMERIC(10,2)  NOT NULL DEFAULT 0,  -- diferença proporcional de upgrade no ciclo
    valor_total      NUMERIC(10,2)  GENERATED ALWAYS AS (valor_plano + valor_upgrade) STORED,
    data_vencimento  DATE           NOT NULL,
    data_pagamento   DATE,
    forma_pagamento  VARCHAR(10),
    status           VARCHAR(10)    NOT NULL DEFAULT 'pendente',
    gerada_em        TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_mensalidade_assinatura FOREIGN KEY (id_assinatura)
        REFERENCES assinatura (id_assinatura),
    CONSTRAINT uq_mensalidade_ciclo UNIQUE (id_assinatura, ciclo_inicio),
    CONSTRAINT ck_mensalidade_ciclo  CHECK (ciclo_fim > ciclo_inicio),
    CONSTRAINT ck_mensalidade_valores CHECK (valor_plano > 0 AND valor_upgrade >= 0),
    CONSTRAINT ck_mensalidade_forma  CHECK (forma_pagamento IS NULL OR forma_pagamento IN
        ('dinheiro', 'pix', 'debito', 'credito', 'boleto')),
    CONSTRAINT ck_mensalidade_status CHECK (status IN ('pendente', 'paga', 'atrasada')),
    CONSTRAINT ck_mensalidade_pago   CHECK ((status = 'paga') = (data_pagamento IS NOT NULL))
);


-- =====================================================================
-- 6. FINANCEIRO DO SALÃO — entradas, saídas, fluxo de caixa e conferência
--    (a mensalidade da plataforma NÃO entra aqui)
-- =====================================================================

-- Onde o salão movimenta dinheiro (caixa, banco...).
CREATE TABLE conta_financeira (
    id_conta  SERIAL       PRIMARY KEY,
    id_salao  INTEGER      NOT NULL,
    nome      VARCHAR(60)  NOT NULL,
    tipo      VARCHAR(10)  NOT NULL,
    CONSTRAINT fk_conta_fin_salao FOREIGN KEY (id_salao)
        REFERENCES salao (id_salao),
    CONSTRAINT uq_conta_fin_nome UNIQUE (id_salao, nome),
    CONSTRAINT uq_conta_fin_salao UNIQUE (id_conta, id_salao),
    CONSTRAINT ck_conta_fin_tipo CHECK (tipo IN ('caixa', 'banco', 'digital'))
);

-- Tipos de receita e de despesa. Cada salão tem a sua lista (criada por gatilho
-- com os valores padrão); o dono escolhe a categoria ao lançar o valor.
CREATE TABLE categoria_financeira (
    id_categoria  SERIAL       PRIMARY KEY,
    id_salao      INTEGER      NOT NULL,
    nome          VARCHAR(60)  NOT NULL,
    tipo          VARCHAR(7)   NOT NULL,
    CONSTRAINT fk_cat_fin_salao FOREIGN KEY (id_salao)
        REFERENCES salao (id_salao),
    CONSTRAINT uq_cat_fin_nome UNIQUE (id_salao, tipo, nome),
    CONSTRAINT uq_cat_fin_salao_tipo UNIQUE (id_categoria, id_salao, tipo),
    CONSTRAINT ck_cat_fin_tipo CHECK (tipo IN ('ENTRADA', 'SAIDA'))
);

-- Contas a pagar = SAIDA pendente; contas a receber = ENTRADA pendente.
-- Fluxo de caixa = soma do que já foi RECEBIDO e PAGO. Conferência = "conferido".
-- As chaves compostas garantem que categoria e conta são do MESMO salão e que
-- a categoria é do mesmo tipo (entrada/saída) do lançamento.
CREATE TABLE lancamento_financeiro (
    id_lancamento  SERIAL         PRIMARY KEY,
    id_salao       INTEGER        NOT NULL,
    id_categoria   INTEGER        NOT NULL,
    id_conta       INTEGER        NOT NULL,
    id_pagamento   INTEGER,                          -- entrada gerada por um pagamento de atendimento
    descricao      VARCHAR(150)   NOT NULL,
    tipo           VARCHAR(7)     NOT NULL,
    natureza       VARCHAR(8),                       -- despesa fixa ou variável
    valor          NUMERIC(12,2)  NOT NULL,
    vencimento     DATE           NOT NULL,
    data_pagamento DATE,
    status         VARCHAR(10)    NOT NULL DEFAULT 'PENDENTE',
    conferido      BOOLEAN        NOT NULL DEFAULT FALSE,
    boleto_codigo  VARCHAR(60),                      -- linha digitável do boleto gerado
    criado_em      TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_lanc_salao FOREIGN KEY (id_salao)
        REFERENCES salao (id_salao),
    CONSTRAINT fk_lanc_categoria FOREIGN KEY (id_categoria, id_salao, tipo)
        REFERENCES categoria_financeira (id_categoria, id_salao, tipo),
    CONSTRAINT fk_lanc_conta FOREIGN KEY (id_conta, id_salao)
        REFERENCES conta_financeira (id_conta, id_salao),
    CONSTRAINT fk_lanc_pagamento FOREIGN KEY (id_pagamento)
        REFERENCES pagamento (id_pagamento),
    CONSTRAINT uq_lanc_pagamento UNIQUE (id_pagamento),       -- o mesmo recebimento não entra duas vezes
    CONSTRAINT ck_lanc_tipo     CHECK (tipo IN ('ENTRADA', 'SAIDA')),
    CONSTRAINT ck_lanc_valor    CHECK (valor > 0),
    CONSTRAINT ck_lanc_natureza CHECK (natureza IN ('fixa', 'variavel') AND tipo = 'SAIDA' OR natureza IS NULL),
    CONSTRAINT ck_lanc_status   CHECK (
        (tipo = 'ENTRADA' AND status IN ('PENDENTE', 'RECEBIDO', 'CANCELADO')) OR
        (tipo = 'SAIDA'   AND status IN ('PENDENTE', 'PAGO',     'CANCELADO'))),
    CONSTRAINT ck_lanc_realizado CHECK (status NOT IN ('RECEBIDO', 'PAGO') OR data_pagamento IS NOT NULL),
    CONSTRAINT ck_lanc_conferido CHECK (NOT conferido OR status IN ('RECEBIDO', 'PAGO')),
    CONSTRAINT ck_lanc_pagamento CHECK (id_pagamento IS NULL OR tipo = 'ENTRADA')
);


-- =====================================================================
-- 7. COMISSÕES — regra com vigência, cálculo por atendimento, fechamento mensal
-- =====================================================================

-- Entidade fraca de FUNCIONARIO: percentual em um período de vigência.
CREATE TABLE regra_comissao (
    id_funcionario  INTEGER        NOT NULL,
    vigencia_inicio DATE           NOT NULL,
    vigencia_fim    DATE,                             -- NULL = regra vigente
    percentual      NUMERIC(5,2)   NOT NULL,
    CONSTRAINT pk_regra_comissao PRIMARY KEY (id_funcionario, vigencia_inicio),
    CONSTRAINT fk_regra_funcionario FOREIGN KEY (id_funcionario)
        REFERENCES funcionario (id_funcionario),
    CONSTRAINT ck_regra_percentual CHECK (percentual BETWEEN 0 AND 100),
    CONSTRAINT ck_regra_periodo    CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
    -- em cada data há no máximo uma regra vigente
    CONSTRAINT ex_regra_sem_sobreposicao EXCLUDE USING gist (
        id_funcionario WITH =,
        daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&
    )
);

-- Fechamento do mês de um funcionário em uma unidade (lotação).
CREATE TABLE fechamento_comissao (
    id_fechamento    SERIAL         PRIMARY KEY,
    id_lotacao       INTEGER        NOT NULL,
    id_lancamento    INTEGER,                          -- saída financeira do pagamento ao funcionário
    mes_referencia   DATE           NOT NULL,          -- sempre o dia 1
    valor_total      NUMERIC(12,2)  NOT NULL,          -- soma das comissões do fechamento
    data_fechamento  DATE           NOT NULL,
    data_pagamento   DATE,
    status           VARCHAR(10)    NOT NULL DEFAULT 'fechado',
    CONSTRAINT fk_fechamento_lotacao FOREIGN KEY (id_lotacao)
        REFERENCES lotacao (id_lotacao),
    CONSTRAINT fk_fechamento_lancamento FOREIGN KEY (id_lancamento)
        REFERENCES lancamento_financeiro (id_lancamento),
    CONSTRAINT uq_fechamento_lancamento UNIQUE (id_lancamento),
    CONSTRAINT uq_fechamento_mes UNIQUE (id_lotacao, mes_referencia),
    CONSTRAINT ck_fechamento_mes    CHECK (EXTRACT(DAY FROM mes_referencia) = 1),
    CONSTRAINT ck_fechamento_valor  CHECK (valor_total >= 0),
    CONSTRAINT ck_fechamento_status CHECK (status IN ('fechado', 'pago')),
    CONSTRAINT ck_fechamento_pago   CHECK ((status = 'pago') = (data_pagamento IS NOT NULL))
);

-- Comissão de um atendimento quitado. Percentual e base são copiados no
-- momento do cálculo, então um reajuste de regra não muda o passado.
CREATE TABLE comissao (
    id_comissao          SERIAL         PRIMARY KEY,
    id_agendamento       INTEGER        NOT NULL,
    id_fechamento        INTEGER,                      -- NULL até o fechamento do mês
    percentual_aplicado  NUMERIC(5,2)   NOT NULL,
    valor_base           NUMERIC(10,2)  NOT NULL,
    valor_comissao       NUMERIC(10,2)  NOT NULL,      -- base x percentual, 2 casas
    data_calculo         TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_comissao_agendamento FOREIGN KEY (id_agendamento)
        REFERENCES agendamento (id_agendamento),
    CONSTRAINT fk_comissao_fechamento FOREIGN KEY (id_fechamento)
        REFERENCES fechamento_comissao (id_fechamento),
    CONSTRAINT uq_comissao_agendamento UNIQUE (id_agendamento),     -- no máximo uma por atendimento
    CONSTRAINT ck_comissao_percentual CHECK (percentual_aplicado BETWEEN 0 AND 100),
    CONSTRAINT ck_comissao_valores    CHECK (valor_base >= 0 AND valor_comissao >= 0)
);


-- =====================================================================
-- 8. ÍNDICES DAS CHAVES ESTRANGEIRAS MAIS CONSULTADAS
-- =====================================================================

CREATE INDEX ix_salao_profissional      ON salao (id_profissional);
CREATE INDEX ix_lotacao_salao           ON lotacao (id_salao);
CREATE INDEX ix_servico_funcionario     ON servico (id_funcionario);
CREATE INDEX ix_agendamento_cliente     ON agendamento (id_cliente);
CREATE INDEX ix_agendamento_inicio      ON agendamento (data_hora_inicio);
CREATE INDEX ix_pagamento_agendamento   ON pagamento (id_agendamento);
CREATE INDEX ix_lancamento_salao_venc   ON lancamento_financeiro (id_salao, vencimento);
CREATE INDEX ix_comissao_fechamento     ON comissao (id_fechamento);


-- =====================================================================
-- 9. REGRAS DE NEGÓCIO PROTEGIDAS PELO BANCO (gatilhos)
-- =====================================================================

-- Agendamento: dentro do período da lotação, do horário da unidade e no mesmo
-- dia; novos agendamentos só em unidade ativa e não suspensa.
CREATE FUNCTION fn_valida_agendamento() RETURNS trigger AS $$
DECLARE
    l  lotacao%ROWTYPE;
    h  horario_funcionamento%ROWTYPE;
    s  salao%ROWTYPE;
BEGIN
    SELECT * INTO l FROM lotacao WHERE id_lotacao = NEW.id_lotacao;
    SELECT * INTO s FROM salao   WHERE id_salao   = l.id_salao;

    IF TG_OP = 'INSERT' AND (NOT s.ativo OR s.suspenso) THEN
        RAISE EXCEPTION 'A unidade está desativada ou suspensa para novos agendamentos';
    END IF;

    IF NEW.data_hora_inicio::date < l.data_inicio
       OR (l.data_fim IS NOT NULL AND NEW.data_hora_fim::date > l.data_fim) THEN
        RAISE EXCEPTION 'Agendamento fora do período em que o funcionário atua na unidade';
    END IF;

    IF NEW.data_hora_inicio::date <> NEW.data_hora_fim::date THEN
        RAISE EXCEPTION 'O agendamento deve começar e terminar no mesmo dia';
    END IF;

    SELECT * INTO h FROM horario_funcionamento
     WHERE id_salao = l.id_salao
       AND dia_semana = EXTRACT(DOW FROM NEW.data_hora_inicio)::int;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'A unidade não abre nesse dia da semana';
    END IF;

    IF NEW.data_hora_inicio::time < h.hora_abertura
       OR NEW.data_hora_fim::time > h.hora_fechamento THEN
        RAISE EXCEPTION 'Agendamento fora do horário de funcionamento da unidade';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_agendamento_valida
    BEFORE INSERT OR UPDATE OF id_lotacao, data_hora_inicio, data_hora_fim
    ON agendamento
    FOR EACH ROW EXECUTE FUNCTION fn_valida_agendamento();

-- Plano: ao concluir um atendimento, o dono precisa ter assinatura ativa e o
-- limite semanal (segunda a domingo) não pode ser ultrapassado. Conta cada
-- atendimento concluído; cancelados e faltas não consomem o limite.
CREATE FUNCTION fn_limite_semanal() RETURNS trigger AS $$
DECLARE
    prof     INTEGER;
    lim      INTEGER;
    usados   INTEGER;
BEGIN
    IF NEW.status <> 'concluido' OR (TG_OP = 'UPDATE' AND OLD.status = 'concluido') THEN
        RETURN NEW;
    END IF;

    SELECT s.id_profissional INTO prof
      FROM lotacao l JOIN salao s ON s.id_salao = l.id_salao
     WHERE l.id_lotacao = NEW.id_lotacao;

    SELECT p.limite_semanal INTO lim
      FROM assinatura a JOIN plano p ON p.id_plano = a.id_plano
     WHERE a.id_profissional = prof
       AND a.status = 'ativa'
       AND a.data_inicio <= NEW.data_hora_inicio::date
       AND (a.data_fim IS NULL OR a.data_fim >= NEW.data_hora_inicio::date);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'O dono da unidade não tem assinatura ativa na data do atendimento';
    END IF;
    IF lim IS NULL THEN
        RETURN NEW;                       -- plano ilimitado
    END IF;

    SELECT COUNT(*) INTO usados
      FROM agendamento a
      JOIN lotacao l ON l.id_lotacao = a.id_lotacao
      JOIN salao s   ON s.id_salao   = l.id_salao
     WHERE s.id_profissional = prof
       AND a.status = 'concluido'
       AND date_trunc('week', a.data_hora_inicio) = date_trunc('week', NEW.data_hora_inicio)
       AND a.id_agendamento IS DISTINCT FROM NEW.id_agendamento;

    IF usados >= lim THEN
        RAISE EXCEPTION 'Limite semanal do plano atingido (% de %): aguarde a próxima semana ou faça upgrade',
            usados, lim;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_agendamento_limite_semanal
    BEFORE INSERT OR UPDATE OF status
    ON agendamento
    FOR EACH ROW EXECUTE FUNCTION fn_limite_semanal();

-- O serviço do item precisa ser do funcionário que atende o agendamento.
CREATE FUNCTION fn_valida_item_agendamento() RETURNS trigger AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM agendamento a
          JOIN lotacao l ON l.id_lotacao = a.id_lotacao
          JOIN servico s ON s.id_funcionario = l.id_funcionario
         WHERE a.id_agendamento = NEW.id_agendamento
           AND s.id_servico     = NEW.id_servico
    ) THEN
        RAISE EXCEPTION 'O serviço não é oferecido pelo funcionário deste agendamento';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_item_agendamento_valida
    BEFORE INSERT OR UPDATE OF id_agendamento, id_servico
    ON item_agendamento
    FOR EACH ROW EXECUTE FUNCTION fn_valida_item_agendamento();

-- Pagamento só depois da conclusão; o total aprovado nunca passa da soma dos
-- preços cobrados (quitado quando for igual).
CREATE FUNCTION fn_valida_pagamento() RETURNS trigger AS $$
DECLARE
    st      VARCHAR(20);
    total   NUMERIC(12,2);
    pago    NUMERIC(12,2);
BEGIN
    SELECT status INTO st FROM agendamento WHERE id_agendamento = NEW.id_agendamento;
    IF st <> 'concluido' THEN
        RAISE EXCEPTION 'Só é possível registrar pagamento de um agendamento concluído';
    END IF;

    IF NEW.status = 'aprovado' THEN
        SELECT COALESCE(SUM(preco_cobrado), 0) INTO total
          FROM item_agendamento WHERE id_agendamento = NEW.id_agendamento;
        SELECT COALESCE(SUM(valor), 0) INTO pago
          FROM pagamento
         WHERE id_agendamento = NEW.id_agendamento
           AND status = 'aprovado'
           AND id_pagamento IS DISTINCT FROM NEW.id_pagamento;
        IF pago + NEW.valor > total THEN
            RAISE EXCEPTION 'O total aprovado (%) passaria do valor do agendamento (%)',
                pago + NEW.valor, total;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_pagamento_valida
    BEFORE INSERT OR UPDATE OF valor, status
    ON pagamento
    FOR EACH ROW EXECUTE FUNCTION fn_valida_pagamento();

-- Só se avalia um atendimento concluído.
CREATE FUNCTION fn_valida_avaliacao() RETURNS trigger AS $$
BEGIN
    IF (SELECT status FROM agendamento WHERE id_agendamento = NEW.id_agendamento) <> 'concluido' THEN
        RAISE EXCEPTION 'Só é possível avaliar um agendamento concluído';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_avaliacao_valida
    BEFORE INSERT ON avaliacao
    FOR EACH ROW EXECUTE FUNCTION fn_valida_avaliacao();

-- Histórico de assinatura: registra a contratação e cada troca de plano. No
-- upgrade, calcula a diferença proporcional aos dias que faltam no ciclo mensal
-- e aplica o novo limite NA HORA à semana em andamento.
CREATE FUNCTION fn_assinatura_historico() RETURNS trigger AS $$
DECLARE
    p_ant       plano%ROWTYPE;
    p_novo      plano%ROWTYPE;
    dias_rest   INTEGER;
    dias_ciclo  INTEGER;
    dif         NUMERIC(10,2);
    tp          VARCHAR(15);
BEGIN
    SELECT * INTO p_novo FROM plano WHERE id_plano = NEW.id_plano;

    IF TG_OP = 'INSERT' THEN
        INSERT INTO historico_assinatura (id_assinatura, id_plano_anterior, id_plano_novo, tipo)
        VALUES (NEW.id_assinatura, NULL, NEW.id_plano, 'contratacao');
    ELSIF NEW.id_plano <> OLD.id_plano THEN
        SELECT * INTO p_ant FROM plano WHERE id_plano = OLD.id_plano;
        tp  := CASE WHEN p_novo.preco > p_ant.preco THEN 'upgrade' ELSE 'downgrade' END;
        dif := NULL;
        IF tp = 'upgrade' THEN
            dias_rest  := GREATEST(NEW.data_renovacao - CURRENT_DATE, 0);
            dias_ciclo := NEW.data_renovacao - (NEW.data_renovacao - INTERVAL '1 month')::date;
            dif := ROUND((p_novo.preco - p_ant.preco) * dias_rest / dias_ciclo, 2);
        END IF;
        INSERT INTO historico_assinatura
            (id_assinatura, id_plano_anterior, id_plano_novo, tipo, valor_diferenca)
        VALUES (NEW.id_assinatura, OLD.id_plano, NEW.id_plano, tp, dif);

        UPDATE ciclo_semanal
           SET id_plano = NEW.id_plano, limite_aplicavel = p_novo.limite_semanal
         WHERE id_assinatura = NEW.id_assinatura AND status = 'aberto';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_assinatura_historico
    AFTER INSERT OR UPDATE OF id_plano
    ON assinatura
    FOR EACH ROW EXECUTE FUNCTION fn_assinatura_historico();

-- Ciclo semanal fechado não muda nem é apagado.
CREATE FUNCTION fn_ciclo_imutavel() RETURNS trigger AS $$
BEGIN
    IF OLD.status = 'fechado' THEN
        RAISE EXCEPTION 'Ciclo semanal fechado não pode ser alterado nem apagado: registre um ajuste em ajuste_mensalidade';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_ciclo_imutavel
    BEFORE UPDATE OR DELETE ON ciclo_semanal
    FOR EACH ROW EXECUTE FUNCTION fn_ciclo_imutavel();

-- Ajuste só se aplica a um ciclo já fechado.
CREATE FUNCTION fn_valida_ajuste() RETURNS trigger AS $$
BEGIN
    IF (SELECT status FROM ciclo_semanal WHERE id_ciclo = NEW.id_ciclo) <> 'fechado' THEN
        RAISE EXCEPTION 'Ajuste só pode ser registrado para um ciclo semanal já fechado';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_ajuste_valida
    BEFORE INSERT ON ajuste_mensalidade
    FOR EACH ROW EXECUTE FUNCTION fn_valida_ajuste();

-- Ao cadastrar uma unidade, cria o caixa e as categorias financeiras padrão.
CREATE FUNCTION fn_salao_cria_padroes() RETURNS trigger AS $$
BEGIN
    INSERT INTO conta_financeira (id_salao, nome, tipo) VALUES (NEW.id_salao, 'Caixa', 'caixa');

    INSERT INTO categoria_financeira (id_salao, nome, tipo)
    SELECT NEW.id_salao, n, 'SAIDA'
      FROM unnest(ARRAY['Aluguel', 'Água e energia', 'Internet', 'Produtos de higiene',
                        'Materiais de trabalho', 'Salários', 'Comissões', 'Impostos',
                        'Manutenção de equipamentos', 'Marketing', 'Outros']) AS n;

    INSERT INTO categoria_financeira (id_salao, nome, tipo)
    SELECT NEW.id_salao, n, 'ENTRADA'
      FROM unnest(ARRAY['Serviços', 'Outras receitas']) AS n;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_salao_cria_padroes
    AFTER INSERT ON salao
    FOR EACH ROW EXECUTE FUNCTION fn_salao_cria_padroes();

-- Cada pagamento de atendimento gera (ou atualiza) UMA entrada financeira:
-- aprovado = RECEBIDO, pendente = PENDENTE, estornado/recusado = CANCELADO.
CREATE FUNCTION fn_pagamento_gera_lancamento() RETURNS trigger AS $$
DECLARE
    v_salao  INTEGER;
    v_cat    INTEGER;
    v_conta  INTEGER;
    v_status VARCHAR(10);
BEGIN
    IF NEW.status = 'recusado' THEN
        UPDATE lancamento_financeiro SET status = 'CANCELADO' WHERE id_pagamento = NEW.id_pagamento;
        RETURN NULL;
    END IF;

    SELECT l.id_salao INTO v_salao
      FROM agendamento a JOIN lotacao l ON l.id_lotacao = a.id_lotacao
     WHERE a.id_agendamento = NEW.id_agendamento;
    SELECT id_categoria INTO v_cat FROM categoria_financeira
     WHERE id_salao = v_salao AND tipo = 'ENTRADA' AND nome = 'Serviços';
    SELECT id_conta INTO v_conta FROM conta_financeira
     WHERE id_salao = v_salao ORDER BY id_conta LIMIT 1;

    v_status := CASE NEW.status
                    WHEN 'aprovado'  THEN 'RECEBIDO'
                    WHEN 'estornado' THEN 'CANCELADO'
                    ELSE 'PENDENTE' END;

    INSERT INTO lancamento_financeiro
        (id_salao, id_categoria, id_conta, id_pagamento, descricao, tipo, valor,
         vencimento, data_pagamento, status)
    VALUES
        (v_salao, v_cat, v_conta, NEW.id_pagamento,
         'Pagamento do agendamento ' || NEW.id_agendamento, 'ENTRADA', NEW.valor,
         NEW.data_tentativa::date, NEW.data_aprovacao::date, v_status)
    ON CONFLICT (id_pagamento) DO UPDATE
        SET status = EXCLUDED.status,
            valor  = EXCLUDED.valor,
            data_pagamento = EXCLUDED.data_pagamento;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_pagamento_gera_lancamento
    AFTER INSERT OR UPDATE OF status, valor
    ON pagamento
    FOR EACH ROW EXECUTE FUNCTION fn_pagamento_gera_lancamento();

-- Movimentação já realizada (recebida ou paga) não é apagada.
CREATE FUNCTION fn_lancamento_sem_exclusao() RETURNS trigger AS $$
BEGIN
    IF OLD.status IN ('RECEBIDO', 'PAGO') THEN
        RAISE EXCEPTION 'Movimentação já realizada não pode ser apagada: cancele ou corrija com registro';
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_lancamento_sem_exclusao
    BEFORE DELETE ON lancamento_financeiro
    FOR EACH ROW EXECUTE FUNCTION fn_lancamento_sem_exclusao();

-- Comissão: quando os pagamentos aprovados cobrem o total do agendamento
-- (quitado), calcula a comissão com a regra vigente na data e COPIA o
-- percentual. Antes do fechamento do mês, um estorno recalcula (ou remove) a
-- comissão; depois do fechamento ela não muda.
CREATE FUNCTION fn_pagamento_gera_comissao() RETURNS trigger AS $$
DECLARE
    l      lotacao%ROWTYPE;
    com    comissao%ROWTYPE;
    total  NUMERIC(12,2);
    pago   NUMERIC(12,2);
    pct    NUMERIC(5,2);
    dt     TIMESTAMP;
BEGIN
    SELECT l2.* INTO l
      FROM agendamento a JOIN lotacao l2 ON l2.id_lotacao = a.id_lotacao
     WHERE a.id_agendamento = NEW.id_agendamento;
    SELECT COALESCE(SUM(preco_cobrado), 0) INTO total
      FROM item_agendamento WHERE id_agendamento = NEW.id_agendamento;
    SELECT COALESCE(SUM(valor), 0) INTO pago
      FROM pagamento WHERE id_agendamento = NEW.id_agendamento AND status = 'aprovado';

    SELECT * INTO com FROM comissao WHERE id_agendamento = NEW.id_agendamento;
    IF FOUND THEN
        IF com.id_fechamento IS NULL THEN
            IF pago = 0 THEN
                DELETE FROM comissao WHERE id_comissao = com.id_comissao;
            ELSE
                UPDATE comissao
                   SET valor_base = pago,
                       valor_comissao = ROUND(pago * percentual_aplicado / 100, 2)
                 WHERE id_comissao = com.id_comissao;
            END IF;
        END IF;
        RETURN NULL;
    END IF;

    IF total > 0 AND pago >= total THEN
        dt := COALESCE(NEW.data_aprovacao, CURRENT_TIMESTAMP);
        SELECT percentual INTO pct FROM regra_comissao
         WHERE id_funcionario = l.id_funcionario
           AND vigencia_inicio <= dt::date
           AND (vigencia_fim IS NULL OR vigencia_fim >= dt::date);
        IF FOUND THEN
            INSERT INTO comissao
                (id_agendamento, percentual_aplicado, valor_base, valor_comissao, data_calculo)
            VALUES (NEW.id_agendamento, pct, pago, ROUND(pago * pct / 100, 2), dt);
        END IF;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_pagamento_gera_comissao
    AFTER INSERT OR UPDATE OF status, valor
    ON pagamento
    FOR EACH ROW EXECUTE FUNCTION fn_pagamento_gera_comissao();

-- Comissão já ligada a um fechamento não muda nem é apagada.
CREATE FUNCTION fn_comissao_imutavel() RETURNS trigger AS $$
BEGIN
    IF OLD.id_fechamento IS NOT NULL THEN
        RAISE EXCEPTION 'Comissão de um fechamento não pode ser alterada nem apagada';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_comissao_imutavel
    BEFORE UPDATE OR DELETE ON comissao
    FOR EACH ROW EXECUTE FUNCTION fn_comissao_imutavel();

-- Pagar a mensalidade reativa as unidades suspensas do dono, se não restar
-- outra mensalidade com mais de 15 dias de atraso.
CREATE FUNCTION fn_mensalidade_reativa() RETURNS trigger AS $$
BEGIN
    UPDATE salao s
       SET suspenso = FALSE
      FROM assinatura a
     WHERE a.id_assinatura = NEW.id_assinatura
       AND s.id_profissional = a.id_profissional
       AND s.suspenso
       AND NOT EXISTS (
            SELECT 1
              FROM mensalidade m2
              JOIN assinatura a2 ON a2.id_assinatura = m2.id_assinatura
             WHERE a2.id_profissional = a.id_profissional
               AND m2.status = 'atrasada'
               AND CURRENT_DATE - m2.data_vencimento > 15);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_mensalidade_reativa
    AFTER UPDATE OF status ON mensalidade
    FOR EACH ROW WHEN (NEW.status = 'paga')
    EXECUTE FUNCTION fn_mensalidade_reativa();


-- =====================================================================
-- 10. ROTINAS (chamadas pela aplicação ou por um agendador)
-- =====================================================================

-- Abre (se ainda não existir) o ciclo da semana que contém p_data, com o plano
-- e o limite vigentes. Retorna o id do ciclo.
CREATE FUNCTION fn_abrir_ciclo_semanal(p_id_assinatura INTEGER, p_data DATE)
RETURNS INTEGER AS $$
DECLARE
    v_ini  DATE := date_trunc('week', p_data::timestamp)::date;
    a      assinatura%ROWTYPE;
    pl     plano%ROWTYPE;
    v_id   INTEGER;
BEGIN
    SELECT * INTO a  FROM assinatura WHERE id_assinatura = p_id_assinatura;
    SELECT * INTO pl FROM plano      WHERE id_plano      = a.id_plano;
    INSERT INTO ciclo_semanal (id_assinatura, id_plano, semana_inicio, semana_fim, limite_aplicavel)
    VALUES (p_id_assinatura, a.id_plano, v_ini, v_ini + 6, pl.limite_semanal)
    ON CONFLICT (id_assinatura, semana_inicio) DO NOTHING;
    SELECT id_ciclo INTO v_id FROM ciclo_semanal
     WHERE id_assinatura = p_id_assinatura AND semana_inicio = v_ini;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- Fecha o ciclo: guarda a quantidade de atendimentos concluídos na semana.
CREATE FUNCTION fn_fechar_ciclo_semanal(p_id_ciclo INTEGER) RETURNS VOID AS $$
DECLARE
    c    ciclo_semanal%ROWTYPE;
    qtd  INTEGER;
BEGIN
    SELECT * INTO c FROM ciclo_semanal WHERE id_ciclo = p_id_ciclo;
    SELECT COUNT(*) INTO qtd
      FROM agendamento ag
      JOIN lotacao l ON l.id_lotacao = ag.id_lotacao
      JOIN salao s   ON s.id_salao   = l.id_salao
      JOIN assinatura a ON a.id_profissional = s.id_profissional
     WHERE a.id_assinatura = c.id_assinatura
       AND ag.status = 'concluido'
       AND ag.data_hora_inicio >= c.semana_inicio
       AND ag.data_hora_inicio <  c.semana_fim + 1;
    UPDATE ciclo_semanal
       SET qtd_apurada = qtd, status = 'fechado', data_fechamento = CURRENT_TIMESTAMP
     WHERE id_ciclo = p_id_ciclo;
END;
$$ LANGUAGE plpgsql;

-- Mensalidade vencida vira "atrasada"; com mais de 15 dias de atraso as
-- unidades do dono ficam suspensas para novos agendamentos (histórico e
-- agendamentos já marcados são mantidos).
CREATE FUNCTION fn_aplicar_politica_inadimplencia(p_data DATE DEFAULT CURRENT_DATE)
RETURNS VOID AS $$
BEGIN
    UPDATE mensalidade SET status = 'atrasada'
     WHERE status = 'pendente' AND data_vencimento < p_data;

    UPDATE salao s SET suspenso = TRUE
     WHERE NOT s.suspenso
       AND EXISTS (
            SELECT 1
              FROM mensalidade m
              JOIN assinatura a ON a.id_assinatura = m.id_assinatura
             WHERE a.id_profissional = s.id_profissional
               AND m.status = 'atrasada'
               AND p_data - m.data_vencimento > 15);
END;
$$ LANGUAGE plpgsql;

-- Fecha as comissões abertas do mês: um fechamento por lotação, somando as
-- comissões dos atendimentos quitados no mês. Retorna quantos fechamentos criou.
CREATE FUNCTION fn_fechar_comissoes(p_mes DATE) RETURNS INTEGER AS $$
DECLARE
    v_ini  DATE := date_trunc('month', p_mes::timestamp)::date;
    v_fim  DATE := (date_trunc('month', p_mes::timestamp) + INTERVAL '1 month')::date;
    r      RECORD;
    v_id   INTEGER;
    n      INTEGER := 0;
BEGIN
    FOR r IN
        SELECT a.id_lotacao, SUM(c.valor_comissao) AS total
          FROM comissao c
          JOIN agendamento a ON a.id_agendamento = c.id_agendamento
         WHERE c.id_fechamento IS NULL
           AND c.data_calculo >= v_ini AND c.data_calculo < v_fim
         GROUP BY a.id_lotacao
    LOOP
        INSERT INTO fechamento_comissao (id_lotacao, mes_referencia, valor_total, data_fechamento)
        VALUES (r.id_lotacao, v_ini, r.total, CURRENT_DATE)
        RETURNING id_fechamento INTO v_id;

        UPDATE comissao c SET id_fechamento = v_id
          FROM agendamento a
         WHERE a.id_agendamento = c.id_agendamento
           AND a.id_lotacao = r.id_lotacao
           AND c.id_fechamento IS NULL
           AND c.data_calculo >= v_ini AND c.data_calculo < v_fim;
        n := n + 1;
    END LOOP;
    RETURN n;
END;
$$ LANGUAGE plpgsql;


-- =====================================================================
-- 11. VIEWS (atributos derivados e relatórios do financeiro)
-- =====================================================================

-- FUNCIONARIO.renda_mensal = pagamentos aprovados dos atendimentos dele no mês
CREATE VIEW vw_renda_mensal_funcionario AS
SELECT l.id_funcionario,
       date_trunc('month', p.data_aprovacao)::date AS mes_referencia,
       SUM(p.valor)                                AS renda_mensal
  FROM pagamento p
  JOIN agendamento a ON a.id_agendamento = p.id_agendamento
  JOIN lotacao l     ON l.id_lotacao     = a.id_lotacao
 WHERE p.status = 'aprovado'
 GROUP BY l.id_funcionario, date_trunc('month', p.data_aprovacao);

-- SALAO.renda_mensal = pagamentos aprovados dos atendimentos feitos na unidade
CREATE VIEW vw_renda_mensal_salao AS
SELECT l.id_salao,
       date_trunc('month', p.data_aprovacao)::date AS mes_referencia,
       SUM(p.valor)                                AS renda_mensal
  FROM pagamento p
  JOIN agendamento a ON a.id_agendamento = p.id_agendamento
  JOIN lotacao l     ON l.id_lotacao     = a.id_lotacao
 WHERE p.status = 'aprovado'
 GROUP BY l.id_salao, date_trunc('month', p.data_aprovacao);

-- Consumo semanal do plano: atendimentos concluídos, saldo e aviso de limite
-- próximo (faltam 2 ou menos).
CREATE VIEW vw_consumo_semanal AS
SELECT a.id_assinatura,
       a.id_profissional,
       date_trunc('week', ag.data_hora_inicio)::date AS semana_inicio,
       p.limite_semanal,
       COUNT(*)                                       AS qtd_atendimentos,
       p.limite_semanal - COUNT(*)                    AS restantes,
       (p.limite_semanal IS NOT NULL AND p.limite_semanal - COUNT(*) <= 2) AS perto_do_limite
  FROM agendamento ag
  JOIN lotacao l    ON l.id_lotacao = ag.id_lotacao
  JOIN salao s      ON s.id_salao   = l.id_salao
  JOIN assinatura a ON a.id_profissional = s.id_profissional AND a.status = 'ativa'
  JOIN plano p      ON p.id_plano   = a.id_plano
 WHERE ag.status = 'concluido'
 GROUP BY a.id_assinatura, a.id_profissional, date_trunc('week', ag.data_hora_inicio), p.limite_semanal;

-- Resultado original do ciclo e resultado atualizado depois dos ajustes
CREATE VIEW vw_ciclo_semanal_atualizado AS
SELECT c.id_ciclo,
       c.id_assinatura,
       c.semana_inicio,
       c.qtd_apurada                                           AS qtd_original,
       c.qtd_apurada + COALESCE(SUM(aj.quantidade_corrigida - aj.quantidade_anterior), 0)
                                                               AS qtd_atualizada,
       COUNT(aj.id_ajuste)                                     AS qtd_ajustes
  FROM ciclo_semanal c
  LEFT JOIN ajuste_mensalidade aj ON aj.id_ciclo = c.id_ciclo
 WHERE c.status = 'fechado'
 GROUP BY c.id_ciclo, c.id_assinatura, c.semana_inicio, c.qtd_apurada;

-- Fluxo de caixa: só o que foi efetivamente recebido e pago
CREATE VIEW vw_fluxo_caixa_mensal AS
SELECT id_salao,
       date_trunc('month', data_pagamento)::date                              AS mes_referencia,
       COALESCE(SUM(valor) FILTER (WHERE tipo = 'ENTRADA' AND status = 'RECEBIDO'), 0) AS entradas,
       COALESCE(SUM(valor) FILTER (WHERE tipo = 'SAIDA'   AND status = 'PAGO'), 0)     AS saidas,
       COALESCE(SUM(valor) FILTER (WHERE tipo = 'ENTRADA' AND status = 'RECEBIDO'), 0)
     - COALESCE(SUM(valor) FILTER (WHERE tipo = 'SAIDA'   AND status = 'PAGO'), 0)     AS saldo
  FROM lancamento_financeiro
 WHERE status IN ('RECEBIDO', 'PAGO')
 GROUP BY id_salao, date_trunc('month', data_pagamento);

CREATE VIEW vw_contas_a_pagar AS
SELECT * FROM lancamento_financeiro WHERE tipo = 'SAIDA' AND status = 'PENDENTE';

CREATE VIEW vw_contas_a_receber AS
SELECT * FROM lancamento_financeiro WHERE tipo = 'ENTRADA' AND status = 'PENDENTE';

-- Conciliação: movimentações realizadas que ainda não foram conferidas com o extrato
CREATE VIEW vw_pendentes_conferencia AS
SELECT * FROM lancamento_financeiro
 WHERE status IN ('RECEBIDO', 'PAGO') AND NOT conferido;


-- =====================================================================
-- 12. DADOS DE DOMÍNIO
-- =====================================================================

-- Planos da plataforma (cobrança mensal; limite de clientes por semana).
INSERT INTO plano (nome, preco, limite_semanal, ilimitado) VALUES
    ('Inicial',       150.00, 10,   FALSE),
    ('Intermediário', 270.00, 15,   FALSE),
    ('Ilimitado',     300.00, NULL, TRUE);

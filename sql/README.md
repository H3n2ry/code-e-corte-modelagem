# SQL — Code e Corte

Scripts do banco, em PostgreSQL 14 ou superior.

| Pasta | Conteúdo |
|---|---|
| [`ddl/`](ddl/) | criação do banco, tabelas, restrições, gatilhos, rotinas, views e dados de domínio |

## Como executar

Com o PostgreSQL instalado, a partir da raiz do repositório:

```bash
psql -U postgres -f sql/ddl/01_criar_banco_e_tabelas.sql
```

O script cria o banco `code_e_corte`, conecta nele e monta tudo. Para recriar do zero, rode antes:

```sql
DROP DATABASE IF EXISTS code_e_corte;
```

## O que o script cria

- 25 tabelas e 8 views.
- 14 gatilhos que protegem regras de negócio (agenda, limite semanal do plano, pagamentos, comissões, financeiro).
- 4 rotinas para a aplicação ou um agendador: `fn_abrir_ciclo_semanal`, `fn_fechar_ciclo_semanal`, `fn_aplicar_politica_inadimplencia` e `fn_fechar_comissoes`.
- A extensão `btree_gist`, que acompanha o PostgreSQL. Ela permite impedir conflitos de horário e períodos sobrepostos direto no banco.
- Os 3 planos da plataforma (Inicial, Intermediário e Ilimitado). Ao cadastrar uma unidade, o banco cria sozinho o caixa e as categorias financeiras padrão dela.

A explicação de cada tabela e das decisões está em [`docs/modelo-logico.md`](../docs/modelo-logico.md).

## Como foi testado

O script foi executado do zero em um PostgreSQL vazio, seguido de 98 verificações: conflito de horário, limite semanal do plano, upgrade, pagamento parcial e recusado, comissão, fechamento, financeiro, suspensão por inadimplência e transferência de funcionário. Faltam ainda a massa de dados de demonstração e as consultas gerenciais e de auditoria.

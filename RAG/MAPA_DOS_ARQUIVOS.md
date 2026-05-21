# Mapa dos Arquivos — Castor_DashBoard (Projeto IA Comercial / SENAI)

> Documentação de referência dos arquivos disponibilizados na raiz do workspace.
> Gerada em 15/05/2026.

---

## 1. Escopo da liberação

| Item | Valor |
| :--- | :--- |
| Banco de dados | **Castor_DashBoard** (ERP TOTVS Protheus) |
| Filial | **Somente 0401** |
| Período | **12/12/2023 a 06/05/2026** |
| Formato | Planilhas (`.xlsx` e `.csv`) |
| Finalidade | Desenvolvimento de **agente de IA para a área comercial** — Projeto IA na Indústria, em parceria com o **SENAI** |

Fontes do escopo: imagem de escopo (anexo do chat) + [explicação_codigos-tabelas.md](explica%C3%A7%C3%A3o_codigos-tabelas.md).

---

## 2. Convenções do Protheus (importantes para ler os dados)

- Cada tabela tem um **prefixo** de 2–3 letras que se repete em todas as colunas.
  Ex.: tabela `SA1` → colunas `A1_FILIAL`, `A1_COD`, `A1_NOME`, ...
- Coluna `D_E_L_E_T_` = flag lógica de exclusão. Vazio (`''`) = registro ativo.
  Toda extração filtra `WHERE D_E_L_E_T_ = ''`.
- Coluna `*_FILIAL` é filtrada para `'0401'`.
- Tabelas que começam com **S** = padrão Protheus. Tabelas que começam com
  **Z** = customizações do cliente (Castor).

---

## 3. Documento operacional (origem dos dados)

### [ARQUIVOS PARA ENVIO.sql](ARQUIVOS%20PARA%20ENVIO.sql)
Script SQL contendo **todos os `SELECT` usados para gerar as planilhas**.
Inclui também a legenda de campos críticos de cliente:

- `A1_USTATUS`: 1=Ativo, 2=Inativo, 3=Inadimplente, 4=Bloqueado, 5=Inabilitado
- `A1_MSBLQL`: 1=Ativo, 2=Bloqueado
- `A1_RISCO`: A=Crédito OK | B/C/D=Risco | E=Liberação manual
- `SA1010` exclui ramos de atividade `000134-ECOMMERCE` e `000116-ECOMMERCE`.

---

## 4. Tabelas Protheus disponibilizadas

### 4.1 Cadastros / Dimensões

| Arquivo | Tabela | Conteúdo | Volume |
|---|---|---|---|
| [CC2010.xlsx](CC2010.xlsx) | CC2 | Municípios IBGE (UF + código IBGE + nome) | 5.571 |
| [SA1010.xlsx](SA1010.xlsx) | SA1 | Cadastro de Clientes (status, bloqueio, risco) — sem e‑commerce | 15.010 |
| [SA3010.xlsx](SA3010.xlsx) | SA3 | Vendedores | 584 |
| [SB1010.xlsx](SB1010.xlsx) | SB1 | Descrição genérica do Produto (cadastro mestre) | 6.642 |
| [SBM010.xlsx](SBM010.xlsx) | SBM | Grupo de Produto | 288 |
| [SF4010.csv](SF4010.csv) | SF4 | TES — Tipos de Entrada e Saída (regras fiscais por CFOP) | 298 |
| [SX5010.csv](SX5010.csv) | SX5 | Tabelas genéricas (códigos/legendas do sistema) | 136 |
| [FILIAL.xlsx](FILIAL.xlsx) | SM0/Filial | Dados da filial 0401 | — |

### 4.2 Movimentação / Fatos comerciais

| Arquivo | Tabela | Conteúdo | Volume |
|---|---|---|---|
| [SC5010.csv](SC5010.csv) | SC5 | **Cabeçalho** dos Pedidos de Venda | 17.668 |
| [SC6010.csv](SC6010.csv) | SC6 | **Itens** dos Pedidos de Venda | 204.267 |
| [SF2010.csv](SF2010.csv) | SF2 | **Cabeçalho** das Notas Fiscais de Saída | 16.345 |
| [SD2010.csv](SD2010.csv) | SD2 | **Itens** das Notas Fiscais de Saída | 204.111 |
| [SZ1010.csv](SZ1010.csv) | SZ1 (custom) | Status do cliente **antes e depois** da venda | n/i |
| [ZA7010.csv](ZA7010.csv) | ZA7 (custom) | TMKT — Resumo de ligações de telemarketing | 24.129 |

> ⚠️ Os arquivos `SC5010.csv`, `SC6010.csv` e `SD2010.csv` são grandes
> (>50 MB cada) — ferramentas do VS Code podem precisar de tratamento
> especial para abri‑los.

---

## 5. Dicionários e apoio (metadados)

| Arquivo | Função |
|---|---|
| [SC3010 - Dicionário de Dados.csv](SC3010%20-%20Dicion%C3%A1rio%20de%20Dados.csv) | **Dicionário SX3**: para cada campo registra tabela, ordem, nome, tipo (C/N/D), tamanho, decimais, títulos PT/ES/EN, descrições, picture, validações, contexto. Referência semântica de **todas** as colunas. (Apesar do prefixo no nome do arquivo, o conteúdo é SX3.) |
| [0 - Descrição das Tabelas.xlsx](0%20-%20Descri%C3%A7%C3%A3o%20das%20Tabelas.xlsx) | Descrição funcional de cada tabela (recorte de SX2). |
| [0 - Relacionamentos.xlsx](0%20-%20Relacionamentos.xlsx) | Diagrama/lista de **relacionamentos** entre tabelas. |
| [FATOTEMPO.csv](FATOTEMPO.csv) | **Dimensão tempo** / calendário: `Ano; Semestre; Quadrimestre; Trimestre; Bimestre; Mes; MesAbr; MesCompleto; Semana; DiaSemana; Dia(YYYYMMDD)`. |
| [explicação_codigos-tabelas.md](explica%C3%A7%C3%A3o_codigos-tabelas.md) | Resumo textual do escopo + lista de tabelas e volumes. |
| [Envio de Planilhas - Relacionamento - Dicionario de Dados 06.05.2026.rar](Envio%20de%20Planilhas%20-%20Relacionamento%20-%20Dicionario%20de%20Dados%2006.05.2026.rar) | Pacote consolidado de dicionário + relacionamentos para envio. A pasta extraída de mesmo nome ainda está vazia. |

---

## 6. Relacionamentos principais (modelo lógico)

```
                    CC2 (Municípios)
                       │
                       ▼ (UF + cod_mun)
SA3 (Vendedor) ───► SA1 (Cliente) ◄─── SZ1 (status pré/pós venda)
        │                │
        │                ├──► ZA7 (ligações TMKT)
        ▼                ▼
      SC5 (Pedido cab.) ─── SC6 (Pedido itens) ──► SB1 (Produto) ──► SBM (Grupo)
        │                       │
        │                       └──► SF4 (TES / CFOP)
        ▼
      SF2 (NF saída cab.) ──── SD2 (NF saída itens)
                                  │
                                  └──► SB1 / SF4
```

Chaves típicas de junção:
- **Pedido ↔ Itens**: `C5_NUM = C6_NUM` (+ filial).
- **NF ↔ Itens NF**: `F2_DOC + F2_SERIE + F2_CLIENTE + F2_LOJA = D2_DOC + D2_SERIE + D2_CLIENTE + D2_LOJA`.
- **Cliente**: `A1_COD + A1_LOJA` referenciado em SC5/SF2/ZA7/SZ1.
- **Produto**: `B1_COD` referenciado em SC6/SD2.
- **Vendedor**: `A3_COD` referenciado em SC5/SF2.
- **Município**: `CC2_EST + CC2_CODMUN` referenciado em SA1 (`A1_COD_MUN`).
- **TES**: `F4_CODIGO` referenciado em SC6/SD2 (`C6_TES`, `D2_TES`).
- **Tempo**: `FATOTEMPO.Dia` (YYYYMMDD) ↔ campos `*_EMISSAO`, `C5_EMISSAO`, `F2_EMISSAO`, `D2_EMISSAO`, etc.

---

## 7. Camadas do conjunto

1. **Estrutural / metadados** — `SC3010 (SX3)`, `0 - Descrição das Tabelas`, `0 - Relacionamentos`, `SX5010`, `FILIAL`, `FATOTEMPO`, `explicação_codigos-tabelas.md`, imagem de escopo.
2. **Cadastros (dimensões)** — `SA1`, `SA3`, `SB1`, `SBM`, `CC2`, `SF4`.
3. **Movimentação (fatos)** — `SC5`/`SC6` (pedidos), `SF2`/`SD2` (NFs), `ZA7` (TMKT), `SZ1` (status pré/pós venda).
4. **Origem / extração** — `ARQUIVOS PARA ENVIO.sql`.

---

## 8. Observações para uso no agente de IA

- Sempre filtrar `D_E_L_E_T_ = ''` ao consultar (caso reimportar do ERP).
- Sempre filtrar filial `0401` em tabelas com `*_FILIAL`.
- Datas no Protheus são strings `YYYYMMDD` — fazer join com `FATOTEMPO.Dia`.
- Valores monetários e quantidades vêm em colunas numéricas com separador `,`
  (CSV exportado em locale pt‑BR e delimitador `;`).
- Para semântica de campos desconhecidos consultar o **dicionário SX3** em
  `SC3010 - Dicionário de Dados.csv`.
- Status de cliente: ver legenda no [ARQUIVOS PARA ENVIO.sql](ARQUIVOS%20PARA%20ENVIO.sql)
  (`A1_USTATUS`, `A1_MSBLQL`, `A1_RISCO`).
- `SA1010` **não contém** clientes de e‑commerce (ramos `000134` e `000116`).

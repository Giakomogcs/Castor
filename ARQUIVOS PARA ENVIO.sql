-- INFORMAÇÕES DO BANCO DE DADOS Castor_DashBoard
-- SOMENTE FILIAL 0401
-- DATA INICIO 12/12/20223 A DATA FIM 06/05/2026
--===============================================
--Tabelas de municipios do IBGE 5.571 linhas
SELECT * FROM CC2010 WHERE D_E_L_E_T_ = ''  

--CADASTRO DE CLIENTE MENOS RAMO DE ATIVIDADE 000134-ECOMMERCE E 000116-ECOMMERCE --15.010 linhas
--A1_USTATUS: 1=Ativo, 2=Inativo, 3=Inadimplente, 4=Bloqueado, 5=Inabilitado				
--A1_MSBLQL: Status 1=Ativo,  2=Bloqueado				
--A1_RISCO: A: Crédito Ok | B - C - D: Clientes com Risco | E: Liberação manual
SELECT * FROM SA1010 WHERE D_E_L_E_T_ = ''AND A1_SATIV1 NOT IN('000134','000116')

--Vendedores 584 linhas                    
SELECT * FROM SA3010 WHERE D_E_L_E_T_ = ''  

--Descrição Genérica do Produto 6.642 linhas
SELECT * FROM SB1010 WHERE D_E_L_E_T_ = ''  

--Grupo de Produto 288 linhas             
SELECT * FROM SBM010 WHERE D_E_L_E_T_ = ''

--Pedidos de Venda 17.668 linhas
SELECT * FROM SC5010 WHERE D_E_L_E_T_ = '' AND C5_FILIAL='0401'  

--Itens dos Pedidos de Venda 204.267 linhas   
SELECT * FROM SC6010 WHERE D_E_L_E_T_ = '' AND C6_FILIAL='0401'  

--Cabeçalho das NF de Saída 16.345 linhas
SELECT F2_FILIAL,* FROM SF2010 WHERE D_E_L_E_T_ = '' AND F2_FILIAL='0401' 

--Itens de Venda da NF 204.111 linhas
SELECT * FROM SD2010 WHERE D_E_L_E_T_ = '' AND D2_FILIAL='0401' 

--Tipos de Entrada e Saida  298 linhas
SELECT * FROM SF4010 WHERE D_E_L_E_T_ = '' AND F4_FILIAL='0401'

--Tabelas  136 linhas        
SELECT * FROM SX5010 WHERE D_E_L_E_T_ = '' AND X5_FILIAL='0401'  

--TLMK RESUMO LIGACOES 24.129 
SELECT * FROM ZA7010 WHERE D_E_L_E_T_ = ''  AND ZA7_FILIAL='0401' 

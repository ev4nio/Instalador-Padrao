# Consolidação de interações e instruções — Instalador automatizado para Windows

**Data da consolidação:** 13 de julho de 2026  
**Objetivo:** reunir as solicitações, correções, decisões e observações técnicas relacionadas ao projeto de automação de instalações padrão no Windows.

> Este documento separa a **especificação vigente** do **histórico de ideias e requisitos substituídos**. Em caso de conflito, prevalece a especificação vigente.

## 1. Objetivo geral

Desenvolver um instalador visual para Windows capaz de automatizar a preparação de computadores após formatação, com diferentes conjuntos de programas conforme o perfil do usuário da máquina.

O instalador deve:

- funcionar em Windows 10 e Windows 11;
- executar com privilégios administrativos;
- possuir interface visual;
- permitir escolher um perfil de instalação;
- mostrar previamente quais programas serão instalados;
- permitir desmarcar programas individualmente antes de iniciar;
- executar todos os instaladores de forma silenciosa;
- manter visível apenas a interface do script;
- detectar programas que já estejam instalados;
- baixar automaticamente os programas que possuem endereço oficial público;
- mostrar o progresso dos downloads em tempo real;
- registrar todas as operações e falhas em log;
- continuar ou interromper após uma falha conforme configuração;
- funcionar sem depender de Winget, Chocolatey ou Ninite.

## 2. Formato e arquitetura escolhidos

Foram considerados `.bat`, `.ps1` e `.exe`.

### Decisão vigente

- O código principal será escrito em **PowerShell 5.1 (`.ps1`)**.
- A interface será construída com **WPF**.
- Um arquivo `.bat` será utilizado apenas como iniciador, chamando o PowerShell e solicitando elevação administrativa.
- Depois de validado, o PowerShell poderá ser empacotado como `.exe` e assinado digitalmente.

### Motivos

- `.bat` é limitado para interfaces, downloads com progresso, logs estruturados e tratamento de exceções.
- PowerShell possui integração nativa com Windows, registro, processos, rede, WPF e privilégios administrativos.
- O `.exe` é adequado para distribuição final, mas o código deve ser validado primeiro como `.ps1`.

## 3. Perfis de instalação

### 3.1. Instalação Padrão

Deve instalar:

1. Adobe Acrobat Pro DC 2023;
2. Microsoft 365;
3. Google Chrome comum;
4. Google Drive para computador;
5. TeamViewer Host.

### 3.2. SAC

Deve instalar tudo do perfil Padrão e acrescentar:

6. MicroSIP.

### 3.3. Drivers OAB

Deve instalar tudo do perfil Padrão, sem o MicroSIP, e acrescentar:

6. Instalador Drivers OAB.

O Instalador Drivers OAB é um único arquivo `.exe`. O script deve executá-lo como uma única etapa silenciosa depois dos programas do perfil Padrão.

Representação vigente dos perfis:

```json
{
  "Padrao": ["adobe", "office365", "chrome", "gdrive", "teamviewer"],
  "SAC": ["adobe", "office365", "chrome", "gdrive", "teamviewer", "microsip"],
  "DriversOAB": ["adobe", "office365", "chrome", "gdrive", "teamviewer", "driversoab"]
}
```

## 4. Interface visual

A janela principal deve apresentar:

- título e breve orientação;
- seletor de perfil:
  - Instalação Padrão;
  - SAC;
  - Drivers OAB;
- lista prévia dos programas do perfil;
- caixas de seleção para incluir ou remover itens individualmente;
- opção de **Modo simulação**;
- botão para iniciar a instalação;
- botão para abrir a pasta de logs;
- barra de progresso;
- texto de status da operação atual;
- mensagem final de sucesso ou falha.

Durante a execução, apenas a interface do script deve permanecer visível. As janelas dos instaladores filhos devem ser ocultadas e os processos devem ser aguardados até o encerramento.

## 5. Downloads automáticos

O instalador deve baixar diretamente dos sites oficiais os programas que possuem um endereço público adequado.

### Programas baixados automaticamente

| Programa | Origem configurada | Arquivo local |
|---|---|---|
| Google Chrome comum | Google | `Executáveis\Chrome\chrome_installer.exe` |
| Google Drive para computador | Google | `Executáveis\GoogleDrive\GoogleDriveSetup.exe` |
| TeamViewer Host 64 bits | TeamViewer | `Executáveis\TeamViewer\TeamViewer_Host_Setup_x64.exe` |
| MicroSIP | MicroSIP | `Executáveis\MicroSIP\MicroSIP-3.22.12.exe` |

### Pacotes locais, sem download automático

- Adobe Acrobat Pro DC 2023;
- Microsoft 365 doméstico por `OfficeSetup.exe`;
- Instalador Drivers OAB.

### Comportamento dos downloads

- O download somente deve ocorrer quando o programa não estiver instalado e o instalador ainda não existir no cache.
- O programa deve criar automaticamente as pastas necessárias.
- Downloads parciais devem usar temporariamente a extensão `.download`.
- Arquivos parciais devem ser apagados quando ocorrer falha.
- O log deve registrar URL, destino, tamanho, duração e resultado.
- Para baixar novamente, o instalador correspondente pode ser removido da pasta `Executáveis`.

## 6. Progresso e velocidade

Durante cada download, a interface deve mostrar em tempo real:

- nome do programa;
- percentual concluído;
- megabytes baixados;
- tamanho total, quando informado pelo servidor;
- velocidade média em MB/s;
- conclusão ou falha.

Exemplo de status:

```text
Baixando Google Drive para computador — 42,8/98,4 MB — 7,35 MB/s
```

## 7. Tratamento de falhas de rede

O instalador deve apresentar mensagens diferentes para:

- ausência de internet;
- falha de resolução DNS;
- impossibilidade de conexão com o servidor;
- timeout;
- falha de proxy;
- falha de TLS ou certificado;
- erro HTTP retornado pelo servidor;
- arquivo vazio;
- download interrompido.

Todas as falhas devem ser exibidas pela interface e registradas no log.

## 8. Instalação silenciosa

Todos os programas devem ser executados de forma silenciosa sempre que o instalador oferecer suporte oficial ou compatível.

Parâmetros atualmente previstos:

| Programa | Parâmetros previstos |
|---|---|
| Adobe Acrobat | `/sAll /rs /rps /msi EULA_ACCEPT=YES` |
| Microsoft 365 doméstico | `/quiet` |
| Google Chrome comum | `/silent /install` |
| Google Drive | `--silent --desktop_shortcut` |
| TeamViewer Host | `/S` |
| MicroSIP | `/VERYSILENT /NORESTART` |
| Instalador Drivers OAB | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` |

### Observação importante

Não existe um parâmetro silencioso universal para arquivos `.exe`. O argumento depende da tecnologia usada pelo instalador:

- NSIS costuma aceitar `/S`;
- Inno Setup costuma aceitar `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`;
- MSI utiliza `msiexec /i arquivo.msi /qn /norestart`;
- InstallShield pode usar `/s` ou exigir arquivo de respostas;
- instaladores personalizados podem possuir parâmetros próprios.

O Instalador Drivers OAB foi identificado como um instalador Inno Setup. Ele aceita `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`, configurado no `config.json`. O fato de o script ocultar o processo principal não garante que um instalador incompatível não crie outra janela.

## 9. Adobe Acrobat Pro DC 2023

### Requisito inicial, substituído

A versão vigente instala o Adobe diretamente pelo executável `setup.exe`; não utiliza ISO nem montagem de unidade.

### Decisão vigente

A ISO deixou de ser o caminho utilizado. O script deve executar diretamente:

```text
Executáveis\Adobe\setup.exe
```

Esse endereço é o **caminho de origem do instalador**, e não necessariamente o diretório final de instalação do Acrobat. Coloque o arquivo `setup.exe` em `Executáveis\Adobe` antes da execução.

O script deve:

- verificar se o Acrobat já está instalado;
- verificar se o `setup.exe` existe no caminho informado;
- executar o instalador com parâmetros silenciosos;
- ocultar a janela do processo;
- aguardar o encerramento;
- aceitar os códigos de sucesso configurados;
- registrar resultado e falhas no log.

Depois da instalação do Adobe Reader Pro ele deve chamar um .exe específico que terá que ser instruído no código para que eu possa sinalizar o caminho posteriormente.

## 10. Microsoft 365

### Alternativa analisada e descartada

Foi inicialmente configurado o Office Deployment Tool com:

```xml
<Product ID="O365ProPlusRetail">
```

Essa opção corresponde a uma implantação empresarial e poderia não combinar com Microsoft 365 Personal ou Família. Ela foi removida da especificação vigente.

### Decisão vigente

O usuário fornecerá manualmente o `OfficeSetup.exe` baixado na página oficial da conta Microsoft.

Caminho esperado:

```text
Instalador-Padrao\Executáveis\Office\OfficeSetup.exe
```

O instalador deve:

- verificar se o Microsoft Word já existe;
- localizar o `OfficeSetup.exe` nesse caminho;
- executar o arquivo oculto com `/quiet`;
- aguardar seu encerramento;
- registrar código de saída e resultado;
- não abrir fallback interativo se `/quiet` for rejeitado.

O `OfficeSetup.exe` doméstico não possui a mesma documentação pública de instalação silenciosa fornecida para o Office Deployment Tool empresarial. O arquivo específico deve ser testado. A instalação sendo completada também terá que chamar um comando específico que terá que ser sinalizado o caminho no código para que eu possa incluí-lo, somente após isso poderá ser avançado.

## 11. Google Chrome

### Correção solicitada

O projeto chegou a utilizar o MSI do Chrome Enterprise. Embora esse MSI instale essencialmente o mesmo navegador, o usuário solicitou explicitamente o **Google Chrome comum**, como utilizado por um usuário doméstico.

### Decisão vigente

- Utilizar o instalador comum oficial.
- Baixar automaticamente.
- Executar silenciosamente.
- Detectar a instalação em `%ProgramFiles%\Google\Chrome\Application\chrome.exe`.

## 12. Google Drive

- Baixar o `GoogleDriveSetup.exe` do endereço oficial do Google.
- Instalar silenciosamente.
- Criar atalho na área de trabalho conforme parâmetro configurado.
- Detectar instalação antes de baixar ou executar novamente.

## 13. TeamViewer

- Utilizar o TeamViewer Host de 64 bits.
- Baixar do endereço oficial da TeamViewer.
- Executar silenciosamente.
- Detectar instalação existente antes de repetir a operação.

## 14. MicroSIP

- Pertence somente ao perfil SAC.
- Baixar do site oficial do MicroSIP.
- Executar silenciosamente.
- Detectar instalação existente.
- A URL contém atualmente a versão do arquivo e poderá precisar ser atualizada quando a versão antiga for retirada do servidor.

## 15. Instalador Drivers OAB

Caminho esperado:

```text
Instalador-Padrao\Executáveis\Instalador Drivers OAB\Instalador_Drivers_OAB.exe
```

Requisitos:

- o EXE é o pacote local dos Drivers OAB;
- deve ser tratado como uma única instalação adicional;
- deve ser executado somente no perfil Drivers OAB;
- deve ser executado depois dos componentes do perfil Padrão;
- deve utilizar instalação silenciosa;
- deve permanecer oculto;
- deve ter código de saída e falhas registrados;
- não possui URL pública conhecida e será fornecido localmente;
- se tiver outro nome, deverá ter o caminho alterado no `config.json`.

## 16. Detecção de programas instalados

Antes de baixar ou executar um instalador, o script deve procurar o aplicativo por:

- caminho de executável conhecido; e/ou
- nome exibido nas chaves de desinstalação do Registro do Windows, incluindo programas de 32 e 64 bits.

Se o programa já estiver instalado:

- a etapa deve ser ignorada;
- a interface deve informar “Já instalado”;
- o evento deve ser registrado como sucesso no log.

## 17. Códigos de saída e reinicialização

Por padrão, devem ser considerados sucesso:

- `0`: instalação concluída;
- `1641`: instalação concluída e reinicialização iniciada ou solicitada;
- `3010`: instalação concluída, reinicialização necessária.

Quando houver solicitação de reinicialização, o script deve registrá-la no log sem reiniciar automaticamente, salvo decisão futura explícita.

## 18. Logs

Caminho definido:

```text
C:\ProgramData\InstaladorPadrao\Logs
```

Cada execução deve criar um arquivo como:

```text
install_20260713_083000.log
```

O log deve conter:

- data e hora;
- usuário e computador;
- perfil escolhido;
- indicação de modo real ou simulação;
- programa processado;
- URL de download;
- caminho do arquivo;
- comando ou parâmetros usados, sem expor segredos;
- tamanho e duração do download;
- código de saída;
- solicitações de reinicialização;
- programa já instalado;
- sucesso, aviso ou erro;
- resumo final com quantidades de sucessos e falhas.

Níveis previstos:

```text
[INFO]
[WARN]
[ERROR]
[SUCCESS]
```

## 19. Modo simulação

O modo simulação deve:

- permitir testar a interface e os perfis;
- mostrar quais downloads seriam feitos;
- mostrar quais instaladores locais seriam usados;
- gerar log;
- não baixar arquivos;
- não executar instaladores;
- não alterar o sistema.

## 20. Modo silencioso do próprio script

Além da interface visual, o projeto deve oferecer execução por linha de comando, por exemplo:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Installer.ps1 -Silent -Profile SAC
```

Perfis aceitos:

```text
Padrao
SAC
DriversOAB
```

Também deve ser possível combinar com `-DryRun`.

Para uma simulação completa, inclusive quando os executáveis locais ainda não foram colocados em `Executáveis`, execute:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Installer.ps1 -Silent -Profile Padrao -DryRun
```

Para testar pela interface sem solicitar elevação, execute:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Installer.ps1 -DryRun
```

A caixa **Modo simulação** será aberta já marcada. Nesse modo, as etapas não são ignoradas por detecção de programas já instalados: o fluxo completo é apenas registrado no log, sem baixar, executar ou alterar arquivos.

## 21. Estrutura vigente do projeto

```text
Instalador-Padrao/
  Iniciar-Instalador.bat
  Installer.ps1
  config.json
  Executáveis/
    Adobe/
      setup.exe                            # fornecido manualmente
    Office/
      OfficeSetup.exe                      # fornecido manualmente
    Chrome/
      chrome_installer.exe                 # baixado automaticamente
    GoogleDrive/
      GoogleDriveSetup.exe                 # baixado automaticamente
    MicroSIP/
      MicroSIP-3.22.12.exe                 # baixado automaticamente
    Instalador Drivers OAB/
      Instalador_Drivers_OAB.exe           # fornecido manualmente
    TeamViewer/
      TeamViewer_Host_Setup_x64.exe        # baixado automaticamente
```

Os instaladores do Adobe e do Office devem ficar nas pastas locais `Executáveis\Adobe` e `Executáveis\Office`.

Durante a execução, os instaladores locais em `Executáveis` são executados diretamente dessa pasta. Somente os programas baixados da internet são gravados em `%USERPROFILE%\Downloads\InstaladorPadrao\<aplicativo>`; após o instalador retornar um código de sucesso configurado, essa pasta temporária é removida.

## 22. Histórico anterior relacionado

Antes da especificação atual, foram discutidos outros instaladores pós-formatação. Esses itens são preservados como histórico, mas **não fazem parte automaticamente da versão vigente**.

## 24. Pontos que ainda exigem teste em Windows

1. Confirmar se o `OfficeSetup.exe` doméstico aceita `/quiet` sem abrir interface.
2. Confirmar o comportamento da instalação de Drivers OAB em uma máquina de teste.
3. Confirmar os parâmetros exatos do `setup.exe` do Adobe colocado em `Executáveis\Adobe`.
4. Confirmar se o TeamViewer desejado é realmente o Host e não o cliente completo.
5. Validar os códigos de saída reais de cada instalador.
6. Validar detecção após instalação e eventual atraso até os arquivos aparecerem.
7. Confirmar o comportamento quando os executáveis locais não forem colocados nas pastas `Executáveis`.
8. Testar toda a interface WPF em Windows PowerShell 5.1.
9. Testar execução em Windows 10 e Windows 11 recém-formatados.
10. Atualizar o endereço/versionamento do MicroSIP quando necessário.

## 25. Resultado esperado

Ao iniciar o projeto, o técnico deve visualizar somente a janela do Instalador Padrão, escolher um perfil, revisar os programas e iniciar. O script deve então:

1. solicitar elevação administrativa;
2. verificar o que já está instalado;
3. verificar a disponibilidade dos pacotes locais;
4. baixar os pacotes oficiais necessários;
5. mostrar percentual, megabytes e MB/s;
6. executar cada instalação silenciosamente;
7. manter os instaladores filhos ocultos;
8. registrar todas as operações;
9. continuar conforme a política de erros;
10. apresentar um resumo final com sucesso ou falhas e o caminho do log.

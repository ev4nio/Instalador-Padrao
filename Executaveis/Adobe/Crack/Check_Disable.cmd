@ECHO OFF
TITLE Блокировка адресов, ответственных за проверку лицензий Adobe CC

ECHO Блокировка в файле hosts адресов, ответственных за проверку
ECHO легитимности лицензий продуктов семейства Adobe CC
ECHO _______________________________________________________________________
ECHO.
REN %WINDIR%\system32\drivers\etc\hosts hosts77 > nul
IF %ERRORLEVEL% NEQ 0 (
  ECHO Файл hosts заблокирован для редактирования.
  ECHO.
  ECHO Либо Вы запустили данный патч не от имени администратора,
  ECHO либо внесение изменений блокирует установленный у Вас антивирус.
  ECHO.
  ECHO.
  PAUSE
  EXIT
)
REN %WINDIR%\system32\drivers\etc\hosts77 hosts > nul
FIND /c /i "na1r.services.adobe.com" %WINDIR%\system32\drivers\etc\hosts > nul
IF %ERRORLEVEL% NEQ 0 (
  ECHO ^127.0.0.1 na1r.services.adobe.com >> %WINDIR%\system32\drivers\etc\hosts
  ECHO Адрес na1r.services.adobe.com успешно добавлен в файл hosts.
) ELSE (
  ECHO Адрес na1r.services.adobe.com уже имеется в файле hosts.
)
ECHO.
FIND /c /i "hlrcv.stage.adobe.com" %WINDIR%\system32\drivers\etc\hosts > nul
IF %ERRORLEVEL% NEQ 0 (
  ECHO ^127.0.0.1 hlrcv.stage.adobe.com >> %WINDIR%\system32\drivers\etc\hosts
  ECHO Адрес hlrcv.stage.adobe.com успешно добавлен в файл hosts.
) ELSE (
  ECHO Адрес hlrcv.stage.adobe.com уже имеется в файле hosts.
)
ECHO.
FIND /c /i "lmlicenses.wip4.adobe.com" %WINDIR%\system32\drivers\etc\hosts > nul
IF %ERRORLEVEL% NEQ 0 (
  ECHO ^127.0.0.1 lmlicenses.wip4.adobe.com >> %WINDIR%\system32\drivers\etc\hosts
  ECHO Адрес lmlicenses.wip4.adobe.com успешно добавлен в файл hosts.
) ELSE (
  ECHO Адрес lmlicenses.wip4.adobe.com уже имеется в файле hosts.
)
ECHO.
FIND /c /i "lm.licenses.adobe.com" %WINDIR%\system32\drivers\etc\hosts > nul
IF %ERRORLEVEL% NEQ 0 (
  ECHO ^127.0.0.1 lm.licenses.adobe.com >> %WINDIR%\system32\drivers\etc\hosts
  ECHO Адрес lm.licenses.adobe.com успешно добавлен в файл hosts.
) ELSE (
  ECHO Адрес lm.licenses.adobe.com уже имеется в файле hosts.
)
ECHO.
FIND /c /i " activate.adobe.com" %WINDIR%\system32\drivers\etc\hosts > nul
IF %ERRORLEVEL% NEQ 0 (
  ECHO ^127.0.0.1 activate.adobe.com >> %WINDIR%\system32\drivers\etc\hosts
  ECHO Адрес activate.adobe.com успешно добавлен в файл hosts.
) ELSE (
  ECHO Адрес activate.adobe.com уже имеется в файле hosts.
)
ECHO.
FIND /c /i "practivate.adobe.com" %WINDIR%\system32\drivers\etc\hosts > nul
IF %ERRORLEVEL% NEQ 0 (
  ECHO ^127.0.0.1 practivate.adobe.com >> %WINDIR%\system32\drivers\etc\hosts
  ECHO Адрес practivate.adobe.com успешно добавлен в файл hosts.
) ELSE (
  ECHO Адрес practivate.adobe.com уже имеется в файле hosts.
)
ECHO.
ipconfig /flushdns > nul
ECHO Кэш сопоставителя DNS успешно очищен.
ECHO _______________________________________________________________________
ECHO.
ECHO Все необходимые изменения успешно внесены!
ECHO.
ECHO.
PAUSE
; Wolf Leader installer for Windows (Inno Setup 6.3+). Built by build.bat:
;   ISCC.exe /Qp /DAppVersion=x.y.z installer\windows\WolfLeader.iss
; The wizard collects the answer file (installer/CONFIG.md) from the user's own AI agent, then
; runs install.ps1, which does the real work. Per-user install, no admin needed (winget elevates itself).
;
; Test hook (no wizard, nothing installed): WolfLeaderSetup.exe /CURRENTUSER /WLVALIDATE=<ini> /WLRESULT=<out>
; writes "OK" or "FAIL: <first bad line>" to <out> using the same validator as the paste page.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "Wolf Leader"
#define RepoDir SourcePath + "..\..\"
#define AssetDir SourcePath + "..\assets\"

[Setup]
; Fixed AppId: re-running setup updates the existing install instead of adding a second one
AppId={{6D9F3511-8CA4-4C12-974D-8CBA6384F2F4}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Wolf Leader
DefaultDirName={localappdata}\WolfLeader
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UsedUserAreasWarning=no
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
WizardSizePercent=120
#if FileExists(AssetDir + "wizard-side.bmp")
WizardImageFile={#AssetDir}wizard-side.bmp
#endif
#if FileExists(AssetDir + "wizard-small.bmp")
WizardSmallImageFile={#AssetDir}wizard-small.bmp
#endif
#if FileExists(AssetDir + "wolfleader.ico")
SetupIconFile={#AssetDir}wolfleader.ico
UninstallDisplayIcon={app}\wolfleader.ico
#endif
Compression=lzma2/max
SolidCompression=yes
OutputDir=..\..\dist
OutputBaseFilename=WolfLeaderSetup-{#AppVersion}
UninstallDisplayName={#AppName}
CloseApplications=no
SetupLogging=yes
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Wizard-only files (never copied to {app})
Source: "..\PROMPT.md"; Flags: dontcopy
#if FileExists(AssetDir + "whatsnew-cards.bmp")
  #define HasCards
Source: "{#AssetDir}whatsnew-cards.bmp"; Flags: dontcopy
#endif

; Client files + the installer script (every mode)
#if FileExists(AssetDir + "wolfleader.ico")
Source: "{#AssetDir}wolfleader.ico"; DestDir: "{app}"; Flags: ignoreversion
#endif
Source: "install.ps1"; DestDir: "{app}\installer\windows"; Flags: ignoreversion
Source: "..\CONFIG.md"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "..\PROMPT.md"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "{#RepoDir}examples\*"; DestDir: "{app}\examples"; Excludes: "__pycache__,*.pyc"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#RepoDir}scripts\*"; DestDir: "{app}\scripts"; Excludes: "__pycache__,*.pyc"; Flags: ignoreversion recursesubdirs createallsubdirs

; Hub sources (mode=new, or update on a PC that already runs a hub)
Source: "{#RepoDir}ide_storage\*"; DestDir: "{app}\ide_storage"; Excludes: "__pycache__,*.pyc"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: NeedHubFiles
Source: "{#RepoDir}wiki\*"; DestDir: "{app}\wiki"; Excludes: "node_modules,\.next,\out,\.source,\next-env.d.ts,*.tsbuildinfo"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: NeedHubFiles
Source: "{#RepoDir}Dockerfile"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedHubFiles
Source: "{#RepoDir}.dockerignore"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedHubFiles
Source: "{#RepoDir}docker-compose*.yml"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedHubFiles
Source: "{#RepoDir}requirements*.txt"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedHubFiles
Source: "{#RepoDir}.env.example"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedHubFiles
Source: "{#RepoDir}start.sh"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedHubFiles

[Run]
Filename: "{code:GetLogPath}"; Description: "Open the install log"; Flags: shellexec postinstall skipifsilent unchecked nowait

[UninstallDelete]
Type: files; Name: "{app}\install-result.ini"

[Code]
const
  Alnum = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  MaxShares = 5;

var
  WhatsNewPage, ModePage, AgentPage, PwPage: TWizardPage;
  ChoicesPage: TInputOptionWizardPage;
  GitPage: TInputQueryWizardPage;
  RadioNew, RadioConnect, RadioUpdate: TNewRadioButton;
  PromptMemo, ReplyMemo: TNewMemo;
  PwLabels: array of TNewStaticText;
  PwEdits: array of TPasswordEdit;
  WikiWasEnabled: Boolean;

  PromptTemplate, AnswerIni, ResultPath, BackupDir: String;
  LineMap, LineText, SectionList: TStringList;

  HubUrl, McpUrl, DeviceName, TimeZone, DetDocker: String;
  BackupDone, BackupPath, BackupFiles: String;
  ShareOn, ShareAsk: array of Boolean;
  ShareUnc, ShareUser, ShareLetter: array of String;

function SetEnvironmentVariable(lpName, lpValue: String): Boolean;
  external 'SetEnvironmentVariableW@kernel32.dll stdcall';
function ClearEnvironmentVariable(lpName: String; lpValue: Cardinal): Boolean;
  external 'SetEnvironmentVariableW@kernel32.dll stdcall';

{ ---------- small helpers ---------- }

function PowerShellExe: String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function GetMode: String;
begin
  if RadioNew.Checked then Result := 'new'
  else if RadioUpdate.Checked then Result := 'update'
  else Result := 'connect';
end;

function ClientOn: Boolean;   begin Result := ChoicesPage.Values[0]; end;
function SharesOn: Boolean;   begin Result := ChoicesPage.Values[1]; end;
function PrereqsOn: Boolean;  begin Result := ChoicesPage.Values[2]; end;
function ObsidianOn: Boolean; begin Result := ChoicesPage.Values[3]; end;
function WikiOn: Boolean;     begin Result := (GetMode = 'new') and ChoicesPage.Values[4]; end;

function NeedHubFiles: Boolean;
begin
  Result := (GetMode = 'new') or ((GetMode = 'update') and FileExists(ExpandConstant('{app}\.env')));
end;

function GetLogPath(Param: String): String;
begin
  Result := GetIniString('result', 'log', ExpandConstant('{localappdata}\WolfLeader\install.log'), ResultPath);
end;

function OnlyChars(const S, Allowed: String): Boolean;
var
  i: Integer;
begin
  Result := Length(S) > 0;
  for i := 1 to Length(S) do
    if Pos(S[i], Allowed) = 0 then
    begin
      Result := False;
      Exit;
    end;
end;

function StartsWith(const S, Prefix: String): Boolean;
begin
  Result := Copy(S, 1, Length(Prefix)) = Prefix;
end;

function IsHttpUrl(const S: String): Boolean;
begin
  Result := ((StartsWith(LowerCase(S), 'http://') and (Length(S) > 7)) or
             (StartsWith(LowerCase(S), 'https://') and (Length(S) > 8))) and (Pos(' ', S) = 0);
end;

function IsAbsWindowsPath(const S: String): Boolean;
begin
  Result := ((Length(S) >= 3) and (Pos(UpperCase(S[1]), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') > 0) and (S[2] = ':') and (S[3] = '\'))
            or (StartsWith(S, '\\') and (Length(S) > 3));
end;

function Utf8ToStr(const A: AnsiString): String;
var
  i, n, b, c, extra: Integer;
begin
  Result := '';
  n := Length(A);
  i := 1;
  while i <= n do
  begin
    b := Ord(A[i]);
    if b < $80 then begin c := b; extra := 0; end
    else if (b and $E0) = $C0 then begin c := b and $1F; extra := 1; end
    else if (b and $F0) = $E0 then begin c := b and $0F; extra := 2; end
    else if (b and $F8) = $F0 then begin c := b and $07; extra := 3; end
    else begin c := $FFFD; extra := 0; end;
    while (extra > 0) and (i < n) do
    begin
      i := i + 1;
      c := (c shl 6) or (Ord(A[i]) and $3F);
      extra := extra - 1;
    end;
    if c > $FFFF then
    begin
      c := c - $10000;
      Result := Result + Chr($D800 + (c shr 10)) + Chr($DC00 + (c and $3FF));
    end else
      Result := Result + Chr(c);
    i := i + 1;
  end;
end;

{ Reads UTF-8 (with or without BOM) or UTF-16LE (with BOM) text. }
function LoadTextFile(const FileName: String): String;
var
  A: AnsiString;
  i: Integer;
begin
  Result := '';
  if not LoadStringFromFile(FileName, A) then Exit;
  if (Length(A) >= 2) and (Ord(A[1]) = $FF) and (Ord(A[2]) = $FE) then
  begin
    i := 3;
    while i < Length(A) do
    begin
      Result := Result + Chr(Ord(A[i]) or (Ord(A[i + 1]) shl 8));
      i := i + 2;
    end;
  end else
    Result := Utf8ToStr(A);
  if (Length(Result) > 0) and (Result[1] = #$FEFF) then
    Result := Copy(Result, 2, Length(Result));
end;

{ ---------- prompt ---------- }

procedure LoadPromptTemplate;
var
  L: TStringList;
  i, First, Second: Integer;
  S: String;
begin
  ExtractTemporaryFile('PROMPT.md');
  L := TStringList.Create;
  try
    L.Text := LoadTextFile(ExpandConstant('{tmp}\PROMPT.md'));
    First := -1;
    Second := -1;
    for i := 0 to L.Count - 1 do
      if Trim(L.Strings[i]) = '---' then
      begin
        if First < 0 then First := i
        else if Second < 0 then Second := i;
      end;
    S := '';
    if (First >= 0) and (Second > First) then
      for i := First + 1 to Second - 1 do
        S := S + L.Strings[i] + #13#10;
    PromptTemplate := Trim(S);
  finally
    L.Free;
  end;
end;

function FilledPrompt: String;
var
  Hint: String;
begin
  Result := PromptTemplate;
  if GetMode = 'new' then Hint := 'http://localhost:6971' else Hint := 'http://wolf.local:6971';
  StringChangeEx(Result, '{{OS}}', 'windows', True);
  StringChangeEx(Result, '{{MODE}}', GetMode, True);
  StringChangeEx(Result, '{{HUB_HINT}}', Hint, True);
end;

procedure CopyPromptClick(Sender: TObject);
var
  F: String;
  Lines: TArrayOfString;
  RC: Integer;
begin
  F := ExpandConstant('{tmp}\wl-prompt.txt');
  SetArrayLength(Lines, 1);
  Lines[0] := PromptMemo.Text;
  if SaveStringsToUTF8File(F, Lines, False) and
     Exec(PowerShellExe, '-NoProfile -NonInteractive -Command "Get-Content -Raw -Encoding UTF8 -LiteralPath ''' + F + ''' | Set-Clipboard"',
          '', SW_HIDE, ewWaitUntilTerminated, RC) and (RC = 0) then
    MsgBox('Prompt copied. Paste it into Cursor, Claude or ChatGPT on THIS computer.', mbInformation, MB_OK)
  else
    MsgBox('Could not copy automatically. Click in the prompt box, press Ctrl+A, then Ctrl+C.', mbError, MB_OK);
end;

procedure LoadReplyClick(Sender: TObject);
var
  FileName: String;
begin
  FileName := '';
  if GetOpenFileName('Open your agent''s reply', FileName, ExpandConstant('{userdocs}'),
                     'Answer files (*.ini;*.txt)|*.ini;*.txt|All files (*.*)|*.*', 'ini') then
    ReplyMemo.Text := LoadTextFile(FileName);
end;

{ ---------- answer file validation (CONFIG.md) ---------- }

function Where(const Sec, Key: String): String;
begin
  if LineMap.IndexOf(Sec + '.' + Key) >= 0 then
    Result := LineText.Strings[LineMap.IndexOf(Sec + '.' + Key)]
  else
    Result := '[' + Sec + '] ' + Key + '= is missing';
end;

function Bad(const Sec, Key, Why: String; var Err: String): Boolean;
begin
  Err := Where(Sec, Key) + #13#10 + Why;
  Result := False;
end;

function IniVal(const Sec, Key: String): String;
begin
  Result := Trim(GetIniString(Sec, Key, '', AnswerIni));
end;

function IsYesNo(const S: String): Boolean;
begin
  Result := (LowerCase(S) = 'yes') or (LowerCase(S) = 'no');
end;

{ Strips the ```ini fences, checks every line's shape, writes the clean INI to AnswerIni,
  then checks every key against CONFIG.md. Err gets the first offending line. }
function ValidateAnswer(const Text: String; var Err: String): Boolean;
var
  L: TStringList;
  i, j, P: Integer;
  Ln, Sec, K, V, Clean, S, Unc, Rest: String;
  Keys: TArrayOfString;
begin
  Result := False;
  Err := '';
  LineMap.Clear;
  LineText.Clear;
  SectionList.Clear;
  Clean := '';
  Sec := '';
  L := TStringList.Create;
  try
    L.Text := Text;
    for i := 0 to L.Count - 1 do
    begin
      Ln := Trim(L.Strings[i]);
      if (Length(Ln) > 0) and (Ln[1] = #$FEFF) then Ln := Trim(Copy(Ln, 2, Length(Ln)));
      if (Ln = '') or StartsWith(Ln, '```') or (Ln[1] = ';') or (Ln[1] = '#') then
        { skip }
      else
      begin
        for j := 1 to Length(Ln) do
          if (Ord(Ln[j]) < 32) or (Ord(Ln[j]) > 126) then
          begin
            Err := 'Line ' + IntToStr(i + 1) + ': ' + Ln + #13#10 + 'contains a character that is not plain ASCII.';
            Exit;
          end;
        if (Ln[1] = '[') and (Ln[Length(Ln)] = ']') then
        begin
          Sec := LowerCase(Trim(Copy(Ln, 2, Length(Ln) - 2)));
          SectionList.Add(Sec);
          Clean := Clean + '[' + Sec + ']' + #13#10;
        end else
        begin
          P := Pos('=', Ln);
          if Sec = '' then
          begin
            Err := 'Line ' + IntToStr(i + 1) + ': ' + Ln + #13#10 + 'comes before any [section].';
            Exit;
          end;
          if P < 2 then
          begin
            Err := 'Line ' + IntToStr(i + 1) + ': ' + Ln + #13#10 + 'is not key=value.';
            Exit;
          end;
          K := LowerCase(Trim(Copy(Ln, 1, P - 1)));
          V := Trim(Copy(Ln, P + 1, Length(Ln)));
          if V = '' then
          begin
            Err := 'Line ' + IntToStr(i + 1) + ': ' + Ln + #13#10 + 'has an empty value.';
            Exit;
          end;
          if LineMap.IndexOf(Sec + '.' + K) < 0 then
          begin
            LineMap.Add(Sec + '.' + K);
            LineText.Add('Line ' + IntToStr(i + 1) + ': ' + Ln);
          end;
          Clean := Clean + K + '=' + V + #13#10;
        end;
      end;
    end;
  finally
    L.Free;
  end;

  if SectionList.IndexOf('wolf') < 0 then
  begin
    Err := 'No [wolf] section found. Paste the whole ```ini block your agent wrote.';
    Exit;
  end;
  if not SaveStringToFile(AnswerIni, Clean, False) then
  begin
    Err := 'Could not write ' + AnswerIni;
    Exit;
  end;

  { [wolf] }
  if IniVal('wolf', 'format') <> '1' then begin Result := Bad('wolf', 'format', 'format must be 1.', Err); Exit; end;
  S := LowerCase(IniVal('wolf', 'os'));
  if S = 'mac' then begin Result := Bad('wolf', 'os', 'This answer was written for a Mac. Run the prompt on THIS Windows PC.', Err); Exit; end;
  if S <> 'windows' then begin Result := Bad('wolf', 'os', 'os must be windows.', Err); Exit; end;
  if not IsHttpUrl(IniVal('wolf', 'hub_url')) then begin Result := Bad('wolf', 'hub_url', 'hub_url must start with http:// or https://', Err); Exit; end;
  if not IsHttpUrl(IniVal('wolf', 'mcp_url')) then begin Result := Bad('wolf', 'mcp_url', 'mcp_url must start with http:// or https://', Err); Exit; end;
  if not OnlyChars(IniVal('wolf', 'timezone'), Alnum + '/_+-') then begin Result := Bad('wolf', 'timezone', 'timezone must be an IANA zone like America/Chicago.', Err); Exit; end;
  S := IniVal('wolf', 'device_name');
  if (Length(S) > 32) or not OnlyChars(S, Alnum + '-') then begin Result := Bad('wolf', 'device_name', 'device_name must be 1-32 letters, digits or hyphens.', Err); Exit; end;

  { [detected] }
  Keys := ['git', 'python', 'docker', 'obsidian', 'cursor', 'claude_code', 'wolf_client'];
  for i := 0 to GetArrayLength(Keys) - 1 do
    if not IsYesNo(IniVal('detected', Keys[i])) then begin Result := Bad('detected', Keys[i], Keys[i] + ' must be yes or no.', Err); Exit; end;
  S := IniVal('detected', 'python_version');
  if (S <> 'NONE') and not OnlyChars(S, '0123456789.') then begin Result := Bad('detected', 'python_version', 'python_version must be like 3.13.1 or NONE.', Err); Exit; end;

  { [backup] }
  if not IsYesNo(IniVal('backup', 'done')) then begin Result := Bad('backup', 'done', 'done must be yes or no.', Err); Exit; end;
  S := IniVal('backup', 'path');
  if (S <> 'NONE') and not IsAbsWindowsPath(S) then begin Result := Bad('backup', 'path', 'path must be an absolute folder like C:\Users\me\WolfLeader-backup-20261006-1240, or NONE.', Err); Exit; end;
  if (LowerCase(IniVal('backup', 'done')) = 'yes') and (S = 'NONE') then begin Result := Bad('backup', 'path', 'done=yes needs the backup folder path.', Err); Exit; end;
  if not OnlyChars(IniVal('backup', 'files'), '0123456789') then begin Result := Bad('backup', 'files', 'files must be digits only.', Err); Exit; end;

  { [share1]..[share5] }
  for i := 1 to MaxShares do
  begin
    Sec := 'share' + IntToStr(i);
    ShareOn[i - 1] := SectionList.IndexOf(Sec) >= 0;
    ShareAsk[i - 1] := False;
    if ShareOn[i - 1] then
    begin
      Unc := IniVal(Sec, 'unc');
      Rest := Copy(Unc, 3, Length(Unc));
      if not StartsWith(Unc, '\\') or (Pos('\', Rest) < 2) or (Pos('\', Rest) = Length(Rest)) then
        begin Result := Bad(Sec, 'unc', 'unc must look like \\server\share.', Err); Exit; end;
      S := UpperCase(IniVal(Sec, 'letter'));
      if (Length(S) <> 1) or (Pos(S, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') = 0) then
        begin Result := Bad(Sec, 'letter', 'letter must be one drive letter A-Z, without the colon.', Err); Exit; end;
      if IniVal(Sec, 'user') = '' then begin Result := Bad(Sec, 'user', 'user must be a username or NONE.', Err); Exit; end;
      V := IniVal(Sec, 'password');
      if (V <> 'ASK') and (V <> 'NONE') then
        begin Result := Bad(Sec, 'password', 'password must be ASK or NONE. Never put a real password here.', Err); Exit; end;
      V := LowerCase(IniVal(Sec, 'role'));
      if (V <> 'wolf') and (V <> 'extra') then begin Result := Bad(Sec, 'role', 'role must be wolf or extra.', Err); Exit; end;
      V := IniVal(Sec, 'smb_url');
      if (V <> '') and (V <> 'NONE') and not StartsWith(LowerCase(V), 'smb://') then
        begin Result := Bad(Sec, 'smb_url', 'smb_url must be NONE or smb://server/share.', Err); Exit; end;
      ShareUnc[i - 1] := Unc;
      ShareLetter[i - 1] := S;
      ShareUser[i - 1] := IniVal(Sec, 'user');
      ShareAsk[i - 1] := IniVal(Sec, 'password') = 'ASK';
    end;
  end;

  HubUrl := IniVal('wolf', 'hub_url');
  McpUrl := IniVal('wolf', 'mcp_url');
  DeviceName := IniVal('wolf', 'device_name');
  TimeZone := IniVal('wolf', 'timezone');
  DetDocker := LowerCase(IniVal('detected', 'docker'));
  BackupDone := LowerCase(IniVal('backup', 'done'));
  BackupPath := IniVal('backup', 'path');
  BackupFiles := IniVal('backup', 'files');
  Result := True;
end;

function AnyAsk: Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to MaxShares - 1 do
    if ShareOn[i] and ShareAsk[i] then Result := True;
end;

{ ---------- setup / wizard ---------- }

procedure InitGlobals;
begin
  LineMap := TStringList.Create;
  LineText := TStringList.Create;
  SectionList := TStringList.Create;
  SetArrayLength(ShareOn, MaxShares);
  SetArrayLength(ShareAsk, MaxShares);
  SetArrayLength(ShareUnc, MaxShares);
  SetArrayLength(ShareUser, MaxShares);
  SetArrayLength(ShareLetter, MaxShares);
  AnswerIni := ExpandConstant('{tmp}\wolf-leader-setup.ini');
  ResultPath := ExpandConstant('{localappdata}\WolfLeader\install-result.ini');
end;

function InitializeSetup: Boolean;
var
  V, R, Err: String;
begin
  Result := True;
  InitGlobals;
  V := ExpandConstant('{param:WLVALIDATE|}');
  if V <> '' then
  begin
    R := ExpandConstant('{param:WLRESULT|}');
    if R = '' then R := V + '.result.txt';
    if ValidateAnswer(LoadTextFile(V), Err) then
      SaveStringToFile(R, 'OK', False)
    else
    begin
      StringChangeEx(Err, #13#10, ' -- ', True);
      SaveStringToFile(R, 'FAIL: ' + Err, False);
    end;
    Result := False;
  end;
end;

function NewLabel(Page: TWizardPage; const Caption: String; Top, Left, Width, Height: Integer): TNewStaticText;
begin
  Result := TNewStaticText.Create(Page);
  Result.Parent := Page.Surface;
  Result.AutoSize := False;
  Result.WordWrap := True;
  Result.Caption := Caption;
  Result.Left := Left;
  Result.Top := Top;
  Result.Width := Width;
  Result.Height := Height;
end;

function NewRadio(Page: TWizardPage; const Caption: String; Top: Integer): TNewRadioButton;
begin
  Result := TNewRadioButton.Create(Page);
  Result.Parent := Page.Surface;
  Result.Caption := Caption;
  Result.Left := 0;
  Result.Top := Top;
  Result.Width := Page.SurfaceWidth;
  Result.Height := ScaleY(20);
end;

procedure CreateWhatsNewPage;
var
  Line: TNewStaticText;
  ImgW, ImgH: Integer;
#ifdef HasCards
  Img: TBitmapImage;
#endif
begin
  WhatsNewPage := CreateCustomPage(wpWelcome, 'Built on v1, now on autopilot', 'What this update adds to Wolf Leader.');
  ImgW := WhatsNewPage.SurfaceWidth;
  if ImgW > ScaleX(417) then ImgW := ScaleX(417);
  ImgH := ImgW * 237 div 417;
#ifdef HasCards
  ExtractTemporaryFile('whatsnew-cards.bmp');
  Img := TBitmapImage.Create(WhatsNewPage);
  Img.Parent := WhatsNewPage.Surface;
  Img.Stretch := True;
  Img.Left := (WhatsNewPage.SurfaceWidth - ImgW) div 2;
  Img.Top := 0;
  Img.Width := ImgW;
  Img.Height := ImgH;
  Img.Bitmap.LoadFromFile(ExpandConstant('{tmp}\whatsnew-cards.bmp'));
#else
  ImgH := 0;
#endif
  Line := NewLabel(WhatsNewPage, 'Setup takes a few minutes: your AI agent checks this PC, you paste its answer, and setup does the rest.',
                   ImgH + ScaleY(10), 0, WhatsNewPage.SurfaceWidth, ScaleY(32));
end;

procedure CreateModePage;
var
  Note: TNewStaticText;
  Y: Integer;
begin
  ModePage := CreateCustomPage(WhatsNewPage.ID, 'Do you already have Wolf Leader?',
    'Pick what this PC should be. One machine runs the hub; every other PC connects to it.');
  Y := 0;
  RadioConnect := NewRadio(ModePage, 'Connect this PC to an existing hub (recommended if you already have a hub)', Y);
  Y := Y + ScaleY(28);
  RadioNew := NewRadio(ModePage, 'New hub on this computer ' + #$2014 + ' Docker (experimental)', Y);
  Y := Y + ScaleY(20);
  Note := NewLabel(ModePage, 'The hub runs in Docker. An always-on box (NAS, Proxmox LXC, Linux server) is the tested setup; ' +
                   'a hub on your desktop works but is experimental.', Y, ScaleX(18), ModePage.SurfaceWidth - ScaleX(18), ScaleY(42));
  Note.Font.Color := clGrayText;
  Y := Y + ScaleY(50);
  RadioUpdate := NewRadio(ModePage, 'Update Wolf Leader files on this PC (already installed)', Y);
  RadioConnect.Checked := True;
end;

procedure CreateChoicesPage;
var
  i: Integer;
begin
  ChoicesPage := CreateInputOptionPage(ModePage.ID, 'What do you want?', 'Tick what setup should do on this PC.',
    'You can run setup again later to add anything you skip.', False, False);
  ChoicesPage.Add('Cursor / Claude Code client (skills + rule + MCP)');
  ChoicesPage.Add('Map network shares');
  ChoicesPage.Add('Install Git + Python if missing');
  ChoicesPage.Add('Install Obsidian ' + #$2014 + ' recommended');
  ChoicesPage.Add('Build the wiki ' + #$2014 + ' highly recommended (new hub only)');
  for i := 0 to 4 do ChoicesPage.Values[i] := True;
  WikiWasEnabled := True;
end;

procedure CreateAgentPage;
var
  Lbl1, Lbl2: TNewStaticText;
  CopyBtn, LoadBtn: TNewButton;
  W, H, BtnW, MemoW, Half: Integer;
begin
  AgentPage := CreateCustomPage(ChoicesPage.ID, 'Ask your AI agent',
    'Your agent checks this PC and writes the settings for setup. It also backs up your configs first.');
  W := AgentPage.SurfaceWidth;
  H := AgentPage.SurfaceHeight;
  BtnW := ScaleX(96);
  MemoW := W - BtnW - ScaleX(8);
  Half := (H - ScaleY(56)) div 2;

  Lbl1 := NewLabel(AgentPage, '1. Copy this prompt:', 0, 0, W, ScaleY(16));
  PromptMemo := TNewMemo.Create(AgentPage);
  PromptMemo.Parent := AgentPage.Surface;
  PromptMemo.SetBounds(0, Lbl1.Top + ScaleY(18), MemoW, Half);
  PromptMemo.ReadOnly := True;
  PromptMemo.ScrollBars := ssVertical;
  PromptMemo.WordWrap := True;

  CopyBtn := TNewButton.Create(AgentPage);
  CopyBtn.Parent := AgentPage.Surface;
  CopyBtn.Caption := 'Copy prompt';
  CopyBtn.SetBounds(W - BtnW, PromptMemo.Top, BtnW, ScaleY(24));
  CopyBtn.OnClick := @CopyPromptClick;

  Lbl2 := NewLabel(AgentPage, '2. Paste this into Cursor/Claude/ChatGPT on THIS computer, then paste its reply below:',
                   PromptMemo.Top + Half + ScaleY(6), 0, W, ScaleY(30));
  ReplyMemo := TNewMemo.Create(AgentPage);
  ReplyMemo.Parent := AgentPage.Surface;
  ReplyMemo.SetBounds(0, Lbl2.Top + ScaleY(32), MemoW, H - (Lbl2.Top + ScaleY(32)));
  ReplyMemo.ScrollBars := ssBoth;
  ReplyMemo.WordWrap := False;
  ReplyMemo.Font.Name := 'Consolas';

  LoadBtn := TNewButton.Create(AgentPage);
  LoadBtn.Parent := AgentPage.Surface;
  LoadBtn.Caption := 'Load file...';
  LoadBtn.SetBounds(W - BtnW, ReplyMemo.Top, BtnW, ScaleY(24));
  LoadBtn.OnClick := @LoadReplyClick;
end;

procedure CreatePasswordPage;
var
  i: Integer;
begin
  PwPage := CreateCustomPage(AgentPage.ID, 'Share passwords',
    'Saved in Windows Credential Manager (like cmdkey). Never written to a file or sent to your agent.');
  SetArrayLength(PwLabels, MaxShares);
  SetArrayLength(PwEdits, MaxShares);
  for i := 0 to MaxShares - 1 do
  begin
    PwLabels[i] := NewLabel(PwPage, '', 0, 0, PwPage.SurfaceWidth, ScaleY(16));
    PwEdits[i] := TPasswordEdit.Create(PwPage);
    PwEdits[i].Parent := PwPage.Surface;
    PwEdits[i].Left := 0;
    PwEdits[i].Width := PwPage.SurfaceWidth;
  end;
end;

procedure LayoutPasswordPage;
var
  i, Y: Integer;
begin
  Y := 0;
  for i := 0 to MaxShares - 1 do
  begin
    PwLabels[i].Visible := ShareOn[i] and ShareAsk[i];
    PwEdits[i].Visible := PwLabels[i].Visible;
    if PwLabels[i].Visible then
    begin
      PwLabels[i].Caption := ShareLetter[i] + ':  ' + ShareUnc[i] + '   (user ' + ShareUser[i] + ')';
      PwLabels[i].Top := Y;
      PwEdits[i].Top := Y + ScaleY(18);
      Y := PwEdits[i].Top + PwEdits[i].Height + ScaleY(10);
    end;
  end;
end;

procedure CreateGitPage;
var
  RC: Integer;
  GitOut: TExecOutput;
begin
  GitPage := CreateInputQueryPage(PwPage.ID, 'Git identity', 'Name and email for git commits on this PC',
    'Used only for local git commits. Real or made-up is fine (e.g. you@example.com) ' + #$2014 +
    ' this stops git from stopping to ask for a GitHub login.');
  GitPage.Add('Name:', False);
  GitPage.Add('Email:', False);
  if ExecAndCaptureOutput(ExpandConstant('{cmd}'), '/c git config --global user.name', '', SW_HIDE, ewWaitUntilTerminated, RC, GitOut) and
     (RC = 0) and (GetArrayLength(GitOut.StdOut) > 0) then
    GitPage.Values[0] := Trim(GitOut.StdOut[0]);
  if ExecAndCaptureOutput(ExpandConstant('{cmd}'), '/c git config --global user.email', '', SW_HIDE, ewWaitUntilTerminated, RC, GitOut) and
     (RC = 0) and (GetArrayLength(GitOut.StdOut) > 0) then
    GitPage.Values[1] := Trim(GitOut.StdOut[0]);
end;

procedure InitializeWizard;
begin
  WizardForm.WelcomeLabel2.Caption :=
    'Hey ' + #$D83D#$DC4B + '  Wolf Leader v1 gave every agent you use one shared memory. This update builds on it: ' +
    'chats save themselves, every project is one question away in any new chat, and you can pick up on any machine.';
  LoadPromptTemplate;
  CreateWhatsNewPage;
  CreateModePage;
  CreateChoicesPage;
  CreateAgentPage;
  CreatePasswordPage;
  CreateGitPage;
end;

procedure DeinitializeSetup;
begin
  if LineMap <> nil then LineMap.Free;
  if LineText <> nil then LineText.Free;
  if SectionList <> nil then SectionList.Free;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  S, Health, Detail, Errors, Vault, Backup: String;
begin
  if CurPageID = ChoicesPage.ID then
  begin
    if GetMode = 'new' then
    begin
      if not WikiWasEnabled then ChoicesPage.Values[4] := True;
      ChoicesPage.CheckListBox.ItemEnabled[4] := True;
    end else
    begin
      ChoicesPage.Values[4] := False;
      ChoicesPage.CheckListBox.ItemEnabled[4] := False;
    end;
    WikiWasEnabled := GetMode = 'new';
  end
  else if CurPageID = AgentPage.ID then
    PromptMemo.Text := FilledPrompt
  else if CurPageID = PwPage.ID then
    LayoutPasswordPage
  else if CurPageID = wpFinished then
  begin
    Health := GetIniString('result', 'health', '', ResultPath);
    Detail := GetIniString('result', 'health_detail', '', ResultPath);
    Errors := GetIniString('result', 'errors', '?', ResultPath);
    Vault := GetIniString('result', 'vault', '', ResultPath);
    Backup := GetIniString('result', 'backup', BackupDir, ResultPath);
    if Errors = '0' then S := 'Wolf Leader is set up on this PC.'
    else S := 'Setup finished with ' + Errors + ' problem(s). The log below lists each one; fix it and run setup again (it is safe to re-run).';
    S := S + #13#10#13#10;
    if Health = 'ok' then S := S + 'Hub health: OK (' + Detail + ')'
    else if Health = 'fail' then S := S + 'Hub health: NOT reachable. ' + Detail + '. Check the hub is running and the URL is right.'
    else S := S + 'Hub health: not checked.';
    S := S + #13#10#13#10 + 'Backup of everything setup changed: ' + Backup + #13#10 +
         'To undo, run restore.ps1 in that folder.';
    S := S + #13#10#13#10 + 'Log: ' + GetLogPath('');
    if ObsidianOn and (Vault <> '') then
      S := S + #13#10#13#10 + 'Open Obsidian vault: in Obsidian choose "Open folder as vault" and pick ' + Vault;
    if ClientOn then
      S := S + #13#10#13#10 + 'Restart Cursor (and Claude Code) so they load the new skills, rule and MCP server.';
    WizardForm.FinishedLabel.Caption := S;
    WizardForm.AdjustLabelHeight(WizardForm.FinishedLabel);
  end;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if PageID = PwPage.ID then Result := not (SharesOn and AnyAsk);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Err, S: String;
  i: Integer;
begin
  Result := True;
  if CurPageID = AgentPage.ID then
  begin
    if Trim(ReplyMemo.Text) = '' then
    begin
      MsgBox('Paste your agent''s reply into the box (or use Load file...) first.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not ValidateAnswer(ReplyMemo.Text, Err) then
    begin
      MsgBox('Setup can''t use this reply yet:' + #13#10#13#10 + Err + #13#10#13#10 +
             'Fix that line (or ask your agent to answer again), then click Next.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if (GetMode = 'new') and (DetDocker <> 'yes') then
      Result := MsgBox('Your agent says Docker is not installed. A new hub runs in Docker Desktop, so that step will fail ' +
                       'until Docker is installed and running.' + #13#10#13#10 + 'Continue anyway?', mbConfirmation, MB_YESNO) = IDYES;
  end
  else if CurPageID = PwPage.ID then
  begin
    for i := 0 to MaxShares - 1 do
      if PwEdits[i].Visible and (PwEdits[i].Text = '') then
      begin
        MsgBox('Enter the password for ' + ShareUnc[i] + '.', mbError, MB_OK);
        Result := False;
        Exit;
      end;
  end
  else if CurPageID = GitPage.ID then
  begin
    S := Trim(GitPage.Values[1]);
    if (Trim(GitPage.Values[0]) = '') or (S = '') then
    begin
      MsgBox('Both name and email are needed. Made-up is fine, e.g. Me / me@example.com.', mbError, MB_OK);
      Result := False;
    end
    else if (Pos('@', S) < 2) or (Pos(' ', S) > 0) or (Pos('"', S + GitPage.Values[0]) > 0) then
    begin
      MsgBox('That email doesn''t look right (no spaces or quotes, needs an @). Example: me@example.com', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function YesNo(B: Boolean): String;
begin
  if B then Result := '[x] ' else Result := '[ ] ';
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  S, M: String;
  i: Integer;
begin
  BackupDir := ExpandConstant('{localappdata}\WolfLeader\backup-') + GetDateTimeString('yyyymmdd-hhnn', #0, #0);
  if GetMode = 'new' then M := 'New hub on this computer (Docker, experimental)'
  else if GetMode = 'update' then M := 'Update Wolf Leader files on this PC'
  else M := 'Connect this PC to an existing hub';
  S := 'Mode:' + NewLine + Space + M + NewLine + NewLine;
  S := S + 'Hub:' + NewLine + Space + 'REST  ' + HubUrl + NewLine + Space + 'MCP   ' + McpUrl + NewLine +
       Space + 'This PC: ' + DeviceName + ', time zone ' + TimeZone + NewLine + NewLine;
  S := S + 'Setup will:' + NewLine +
       Space + YesNo(ClientOn) + 'Install the Cursor / Claude Code client (skills, rule, MCP; no hooks)' + NewLine +
       Space + YesNo(SharesOn) + 'Map network shares' + NewLine +
       Space + YesNo(PrereqsOn) + 'Install Git + Python if missing' + NewLine +
       Space + YesNo(ObsidianOn) + 'Install Obsidian' + NewLine;
  if GetMode = 'new' then
    S := S + Space + YesNo(WikiOn) + 'Build the wiki' + NewLine + Space + '[x] Start the hub with Docker' + NewLine;
  S := S + Space + '[x] Set your git identity and check the hub' + NewLine + NewLine;
  if SharesOn then
  begin
    S := S + 'Shares:' + NewLine;
    M := '';
    for i := 0 to MaxShares - 1 do
      if ShareOn[i] then
      begin
        M := M + Space + ShareLetter[i] + ': -> ' + ShareUnc[i] + '  (user ' + ShareUser[i];
        if ShareAsk[i] then M := M + ', password entered)' else M := M + ', no password)';
        M := M + NewLine;
      end;
    if M = '' then M := Space + '(none in the answer)' + NewLine;
    S := S + M + NewLine;
  end;
  S := S + 'Git identity:' + NewLine + Space + Trim(GitPage.Values[0]) + ' <' + Trim(GitPage.Values[1]) + '>' + NewLine + NewLine;
  S := S + 'Backups:' + NewLine;
  if (BackupDone = 'yes') and DirExists(BackupPath) then
    S := S + Space + 'Your agent''s backup: ' + BackupPath + ' (' + BackupFiles + ' files)' + NewLine
  else if BackupDone = 'yes' then
    S := S + Space + 'WARNING: your agent said it backed up to ' + BackupPath + ', but that folder does not exist.' + NewLine
  else
    S := S + Space + 'WARNING: your agent did not make a backup (done=no).' + NewLine;
  S := S + Space + 'Setup''s own backup (made first): ' + BackupDir + NewLine + NewLine;
  S := S + MemoDirInfo + NewLine + NewLine + 'Log:' + NewLine + Space + ExpandConstant('{localappdata}\WolfLeader\install.log');
  Result := S;
end;

{ ---------- install ---------- }

procedure OnInstallOutput(const S: String; const Error, FirstLine: Boolean);
var
  P: Integer;
  Rest: String;
begin
  if StartsWith(S, '@@STEP ') then
  begin
    Rest := Copy(S, 8, Length(S));
    P := Pos(' ', Rest);
    if P > 0 then
    begin
      WizardForm.ProgressGauge.Position := StrToIntDef(Copy(Rest, 1, P - 1), WizardForm.ProgressGauge.Position);
      WizardForm.StatusLabel.Caption := Copy(Rest, P + 1, Length(Rest));
    end;
  end
  else if Trim(S) <> '' then
    WizardForm.FilenameLabel.Caption := Trim(S);
  Log(S);
end;

procedure RunInstallScript;
var
  Params: String;
  RC, i: Integer;
begin
  WizardForm.StatusLabel.Caption := 'Running the Wolf Leader setup steps...';
  WizardForm.FilenameLabel.Caption := '';
  WizardForm.ProgressGauge.Min := 0;
  WizardForm.ProgressGauge.Max := 100;
  WizardForm.ProgressGauge.Position := 0;
  DeleteFile(ResultPath);

  { Passwords travel only through this process's environment, inherited by install.ps1. }
  for i := 0 to MaxShares - 1 do
    if SharesOn and ShareOn[i] and ShareAsk[i] then
      SetEnvironmentVariable('WL_SHARE' + IntToStr(i + 1) + '_PASSWORD', PwEdits[i].Text);

  Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\installer\windows\install.ps1') + '"' +
            ' -Config "' + AnswerIni + '" -Mode ' + GetMode;
  if ClientOn then Params := Params + ' -Client';
  if SharesOn then Params := Params + ' -Shares';
  if PrereqsOn then Params := Params + ' -Prereqs';
  if ObsidianOn then Params := Params + ' -Obsidian';
  if WikiOn then Params := Params + ' -Wiki';
  Params := Params + ' -GitName "' + Trim(GitPage.Values[0]) + '" -GitEmail "' + Trim(GitPage.Values[1]) + '"' +
            ' -BackupDir "' + BackupDir + '" -ResultFile "' + ResultPath + '"';

  if not ExecAndLogOutput(PowerShellExe, Params, ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, RC, @OnInstallOutput) then
    RC := -1;

  for i := 1 to MaxShares do
    ClearEnvironmentVariable('WL_SHARE' + IntToStr(i) + '_PASSWORD', 0);
  for i := 0 to MaxShares - 1 do
    PwEdits[i].Text := '';
  DeleteFile(AnswerIni);

  if (RC <> 0) and not WizardSilent then
    MsgBox('Some setup steps did not finish (exit code ' + IntToStr(RC) + '). The next page shows what happened; ' +
           'the full log is ' + GetLogPath('') + '.', mbError, MB_OK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then RunInstallScript;
end;

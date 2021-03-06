unit fMain;

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, Dialogs,
  StdCtrls, RedirectConsole, ExtCtrls, IniFiles, ScktComp, JvComponentBase,
  JvTrayIcon, ComCtrls, modRichEdit, StrUtils, ImgList, modSCPUtils, SyncObjs;

type
  TMsgType = (mtUnknown = 0, mtChat = 1, mtWhisper, mtReply, mtSysMsg, mtMOTD, mtEmote);

  TPseuWowCMD = (pwUnknown = 0, pwSay = 1);

  TLogItem = class
    MsgType : TMsgType;
    LogMessage : string;
  end;


  TLogThread = class(TThread)
  protected
    procedure Execute; override;
  public
    LogList : TThreadList;
    currMessage : string;
    currCommand : TPseuWowCMD;
    critWrite : TCriticalSection;

    constructor Create;
    destructor Destroy; override;

    procedure AddMessage(AMsg : string);
    procedure SyncWrite();

    procedure WriteFromPseWow(AString : String);
  end;

  TfrmMain = class(TForm)
    pnlTop: TPanel;
    txtExe: TEdit;
    btnRun: TButton;
    btnExit: TButton;
    servRemote: TServerSocket;
    timerStart: TTimer;
    clientSock: TClientSocket;
    TrayIcon: TJvTrayIcon;
    Console: TRichEdit;
    imgList: TImageList;
    pnlBottom: TPanel;
    grpCmd: TGroupBox;
    comCommand: TComboBox;
    pnlSessionTop: TPanel;
    cbexIcon: TComboBoxEx;
    txtChar: TStaticText;
    chkCleanMessages: TCheckBox;
    pnlTestColor: TPanel;
    procedure btnRunClick(Sender: TObject);
    procedure btnExitClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure timerStartTimer(Sender: TObject);
    procedure servRemoteClientRead(Sender: TObject;
      Socket: TCustomWinSocket);
    procedure FormDestroy(Sender: TObject);
    procedure clientSockConnect(Sender: TObject; Socket: TCustomWinSocket);
    procedure clientSockError(Sender: TObject; Socket: TCustomWinSocket;
      ErrorEvent: TErrorEvent; var ErrorCode: Integer);
    procedure ConsoleResizeRequest(Sender: TObject; Rect: TRect);
    procedure comCommandKeyDown(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure clientSockConnecting(Sender: TObject;
      Socket: TCustomWinSocket);
    procedure cbexIconChange(Sender: TObject);
  private
    { Private declarations }
    Logger : TLogThread;

    App : String;
    Running : Boolean;
    Ready : Boolean;

    function ConsoleCommand(AString : String):Boolean;

    procedure LoadSettings;
    procedure SetupIcons;
    procedure SetIcon(AIndex : Integer; AUpdateINI : Boolean = True);
    procedure LoadPseuSettings(AConFile : string);

    procedure ShutDown;
    procedure Execute(AFile: String);
    procedure Launch;
    procedure Log(AText: String; Color : TColor = clAqua);

    procedure AddHistoryItem(Item : String);

  public
    { Public declarations }
  end;

var
  frmMain: TfrmMain;

implementation
{$R *.DFM}


procedure MyLineOut(s: string); // Output procedure
begin
    frmMain.Logger.AddMessage(s);
end;

{---------TLogThread-----------------------------------------------------------\
\------------------------------------------------------------------------------}

procedure TLogThread.AddMessage(AMsg: string);
var
  NewItem : TLogItem;
begin
  NewItem := TLogItem.Create;
  NewItem.MsgType := mtUnknown;
  NewItem.LogMessage := AMsg;

  LogList.Add(NewItem);
end;

constructor TLogThread.Create;
begin
  inherited Create(true);

  currCommand := pwUnknown;

  LogList := TThreadList.Create;
  critWrite := TCriticalSection.Create;
end;

destructor TLogThread.Destroy;
begin
  FreeAndNil(LogList);
  FreeAndNil(critWrite);
  inherited;
end;

procedure TLogThread.Execute;
var
  List : TList;
  oItem : TLogItem;
begin
  currMessage := '';

  while not (Terminated) do
  begin
    List := LogList.LockList;
    LogList.UnlockList;

    while List.Count > 0 do
    begin
      oItem := TLogItem(List[0]);

      //Do the Stuff

      //If the case of sysmsg that hasn't given |r and we get a new message
      //with <say> in it, write the current message
      if (currMessage <> '') and (AnsiPos('<say>', oItem.LogMessage) <> 0) then
      begin
        currMessage := currMessage + '|r';
        Synchronize(SyncWrite);
        currMessage := '';
      end;

      currMessage := Trim(currMessage + oItem.LogMessage);
      Synchronize(SyncWrite);

      LogList.Remove(oItem);
      oItem.Free;
    end;

    //TT: If we still have something in the buffer just write it
    if currMessage <> '' then
    begin
      //In the case of a SYSMSG without |r
      if AnsiPos('|r',currMessage) = 0 then
        currMessage := currMessage + '|r';
      Synchronize(SyncWrite);
    end;

    SleepEx(100, True);
  end;
end;

procedure TLogThread.SyncWrite;
begin
  critWrite.Acquire;
  WriteFromPseWow(currMessage);
  critWrite.Release;
end;

procedure TLogThread.WriteFromPseWow(AString: String);
var
  mt : TMsgType;
  iPos, iPos2 : Integer;
  bEOL : Boolean;
  NewCommand : TPseuWowCMD;
begin
  //TT: Assume we have EOL
  bEOL := True;
  NewCommand := pwUnknown;

  //TT: Remove the current command display to minimise spam
  if frmMain.chkCleanMessages.Checked then
  begin
    //Get Our New Command
    if AnsiPos('<say>:', AString) <> 0 then
      NewCommand := pwSay;

    //May cause a problem if there is more than cmd data in a received string
    //if (currCommand <> pwUnknown) and (NewCommand = currCommand) then
    //  Exit;

    //We have a new command
    if (NewCommand = pwUnknown) and (currCommand <> pwUnknown) then
    begin
      //Remove redundent PW Command Text
      if (currCommand = pwSay) then
        AnsiReplaceText(AString, '<say>', '');
    end
    else
      currCommand := NewCommand;
  end;

  try
    if Trim(AString) <> '' then
    begin

      if LeftStr(AString, 8) = 'SYSMSG: ' then
      begin
        //Check for end of line |r
        if AnsiPos('|r',AString) = 0 then
        begin
          bEOL := False;

          if RightStr(Trim(AString), 1) = '"' then
            bEOL := True
          else
           Exit;
        end;

        AString := AnsiReplaceText(AString,'|r','');


        if frmMain.chkCleanMessages.Checked then
        begin
          AString := AnsiReplaceText(AString,'SYSMSG: ','');
          AString := AnsiReplaceText(AString, '"', '');
        end;

        //Clean Ups for Say Outputs like lookup etc.
        if frmMain.chkCleanMessages.Checked then
        begin
          if AnsiContainsText(AString, '|Hquest') then
          begin
            AString := AddHilightedItem(AString,'quest');
          end;

          if AnsiContainsText(AString, '|Hitem') then
          begin
            AString := AddHilightedItem(AString,'item');
          end;

          if AnsiContainsText(AString, '|Htele') then
          begin
            AString := AddHilightedItem(AString,'tele');
          end;

          if AnsiContainsText(AString, '|Hspell') then
          begin
            AString := AddHilightedItem(AString,'spell');
          end;

          if AnsiContainsText(AString, '|Hcreature') then
          begin
            AString := AddHilightedItem(AString,'creature');
          end;

          if AnsiContainsText(AString, '|Hobject') then
          begin
            AString := AddHilightedItem(AString,'object');
          end;

        end;

        AddColourToLine(frmMain.Console,AString, );
        Exit;
      end;

      if frmMain.chkCleanMessages.Checked then
        AString := AnsiReplaceText(AString, '"', '');

      AString := AnsiReplaceText(AString,'|r','');

      if LeftStr(AString, 6) = 'CHAT: ' then
      begin
        if frmMain.chkCleanMessages.Checked then
          AString := AnsiReplaceText(AString,'CHAT: ','');

        AddColourToLine(frmMain.Console, AString, clWhite);
        Exit;
      end;

      //Are we doing clean messages?
      if frmMain.chkCleanMessages.Checked then
      begin
        AnsiReplaceText(AString,'"','');
      end;

      //TT: Check for known string headers and color accordingly
      if LeftStr(AString, 6) = 'WHISP:' then
      begin
        if frmMain.chkCleanMessages.Checked then
          AString := AnsiReplaceText(AString,'WHISP: ','');
        AddColouredLine(frmMain.Console,AString, $00FB00FB);
        Exit;
      end;

      if LeftStr(AString, 3) = 'TO ' then
      begin
        if frmMain.chkCleanMessages.Checked then
          AString := AnsiReplaceText(AString,'TO ','');

        AddColouredLine(frmMain.Console,AString, $00FB00FB);
        Exit;
      end;

      if LeftStr(AString, 7) = 'EMOTE: ' then
      begin
        if frmMain.chkCleanMessages.Checked then
          AString := AnsiReplaceText(AString,'EMOTE: ','');
        AddColouredLine(frmMain.Console,AString, clYellow);
        Exit;
      end;

      if LeftStr(AString, 6) = 'MOTD: ' then
      begin
        if frmMain.chkCleanMessages.Checked then
          AString := AnsiReplaceText(AString,'MOTD: ','');

        AddColouredLine(frmMain.Console,AString, clAqua);
        Exit;
      end;

      //This doesnt ADD any color at the moment it just seems to clean up the string a bit
      AddColourToLine(frmMain.Console,AString);
    end;
  finally
    if bEOL then
      currMessage := '';
  end;
end;


{---------TfrmMain-------------------------------------------------------------\
\------------------------------------------------------------------------------}

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  RC_LineOut:=MyLineOut; // set Output

  Logger := TLogThread.Create;
  Logger.Resume;

  SetupIcons;
  LoadSettings;
  Ready := False;
end;

procedure TfrmMain.btnRunClick(Sender: TObject);
var
  IniFile : TInifile;
begin
  IniFile := TIniFile.Create(ExtractFilePath(Application.ExeName)+'Settings.INI');
  IniFile.WriteString('Execute','Application',txtExe.Text);
  IniFile.UpdateFile;
  IniFile.Free;
  RC_Run(txtExe.text); // run frmMain.Console program
end;

procedure TfrmMain.btnExitClick(Sender: TObject);
begin
  ShutDown();
end;

procedure TfrmMain.ShutDown;
begin
  Log('Shut down PseuWow Process',clRed);
  RC_LineIn('!');
  RC_LineIn('quit');
  Sleep(3000);
end;

procedure TfrmMain.Execute(AFile : String);
begin
  //TT: Get Info from PseuWow.conf
  LoadPseuSettings(ExtractFilePath(AFile)+'\conf\PseuWoW.conf');

  //TT: See if we already have a server running
  with clientSock do
  begin
    Port := 8089;
    Open;
  end;


  Running := True;
  pnlTop.Hide;
  comCommand.SetFocus;
  RC_Run(AFile);

end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if RC_ExitCode = STILL_ACTIVE then
  begin
    ShutDown;
    CanClose := True;
  end;
end;

procedure TfrmMain.timerStartTimer(Sender: TObject);
begin
  timerStart.Enabled := False;
  if Ready then
  begin
    //TrayIcon.HideApplication;
    Launch;
    Exit;
  end
  else
  begin
    if clientSock.Active = false then
      clientSock.Active := True;
  end;

  timerStart.Enabled := True;
end;

procedure TfrmMain.servRemoteClientRead(Sender: TObject;
  Socket: TCustomWinSocket);
begin
  RC_LineIn('!');
  RC_LineIn(Socket.ReceiveText);
  Log('Received Remote Commad: ' + Socket.ReceiveText, clGreen );
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  Logger.Terminate;
  FreeAndNil(Logger);
  
  servRemote.Active := False;
end;

procedure TfrmMain.clientSockConnect(Sender: TObject;
  Socket: TCustomWinSocket);
begin

  //World Server Check
  if clientSock.Port = 8085 then
  begin
    Ready := True;
    clientSock.Active := False;
    Log('**** WS Is Ready For Connections ****');
    Launch;
  end;

  //Checking If We Have A listening Console
  if clientSock.Port = 8089 then
  begin
    Log('**** Already Listening ****');
    servRemote.Active := False;
  end;

end;

procedure TfrmMain.clientSockError(Sender: TObject;
  Socket: TCustomWinSocket; ErrorEvent: TErrorEvent;
  var ErrorCode: Integer);
begin
  //World Server Check
  if clientSock.Port = 8085 then
  begin
    Ready := False;
    clientSock.Active := False;
    Log('Still Waiting For Server',clMaroon);
    ErrorCode := 0;
  end
  else
  begin
    Log('No Listening Console', clGreen);
    servRemote.Active := True;
    ErrorCode := 0;
  end;
end;

procedure TfrmMain.Launch;
var
  IniFile : TInifile;
  iIcon : Integer;
begin
  if Ready = False then
    Exit;

  Running := False;
  timerStart.Enabled := False;

  if App <> '' then
    Execute(App)
  else
  begin
    timerStart.Enabled := True;
  end;
end;


procedure TfrmMain.Log(AText: String; Color: TColor);
begin
  AddColouredLine(frmMain.Console,'Console: '+AText, Color);
end;


procedure TfrmMain.ConsoleResizeRequest(Sender: TObject; Rect: TRect);
var
  ScrollMessage: TWMVScroll;
  i : Integer;
begin
  ScrollMessage.Msg := WM_VScroll;

  for i := 0 to Console.Lines.Count do
  begin
    ScrollMessage.ScrollCode := sb_LineDown;
    ScrollMessage.Pos := 0;
    Console.Dispatch(ScrollMessage);
  end;
end;

procedure TfrmMain.comCommandKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if key = VK_RETURN then
  begin
    if frmMain.ConsoleCommand(comCommand.Text) then
    begin
      key := 0;
      Exit;
    end;

    // send command line on Enter Key
    RC_LineIn(comCommand.Text);
    AddHistoryItem(comCommand.Text);
    comCommand.Text := '';
    key:=0;
    Exit;
  end;

  if key = VK_F3 then
  begin
    if comCommand.Items.Count > 0 then
      comCommand.ItemIndex := comCommand.Items.Count -1;
    Key := 0;
    Exit;
  end;

end;

procedure TfrmMain.clientSockConnecting(Sender: TObject;
  Socket: TCustomWinSocket);
begin
  if clientSock.Port = 8085 then
  begin
    Log('Establishing Connection to WS',clGreen);
  end;

  if clientSock.Port = 8089 then
  begin
    Log('Checking For Listening Console',clGreen);
  end;
end;

procedure TfrmMain.AddHistoryItem(Item: String);
begin
  with comCommand do
  begin
    if Items.IndexOf(Item) = -1 then
    begin
      Items.Add(Item);
    end;
  end;
end;

function TfrmMain.ConsoleCommand(AString: String): Boolean;
begin
  Result := False;
  AString := UpperCase(AString);

  if (AString = '!QUIT') or (AString = '!EXIT') then
  begin
    Result := True;
    ShutDown;
    Sleep(1000);
    Close;
  end;

end;

procedure TfrmMain.SetupIcons;
var
  i : Integer;
begin
  cbexIcon.Clear;

  for i := 0 to imgList.Count - 1 do
  begin
    cbexIcon.ItemsEx.AddItem('',i,i,i,0,nil);
  end;

end;

procedure TfrmMain.SetIcon(AIndex : Integer; AUpdateINI : Boolean = True);
var
  IniFile : TInifile;
begin
  try
    IniFile := TIniFile.Create(ExtractFilePath(Application.ExeName)+'Settings.INI');
    if AUpdateINI then
      IniFile.WriteInteger('Look','Icon',AIndex);

    with imgList do
    begin
      GetIcon(AIndex, Application.Icon);
      TrayIcon.IconIndex := AIndex;
    end;
    cbexIcon.ItemIndex := AIndex;
  finally
    if AUpdateINI then
    begin
      IniFile.UpdateFile;
      comCommand.SetFocus;
    end;
    IniFile.Free;
  end;
end;

procedure TfrmMain.LoadSettings;
var
  IniFile : TInifile;
  iIcon : Integer;
begin
  try
    //TT: Read from Inifile for the path the file we want.
    IniFile := TIniFile.Create(ExtractFilePath(Application.ExeName)+'Settings.INI');
    App := IniFile.ReadString('Execute','Application','');
    if App = '' then
    begin
      if FileExists(ExtractFilePath(Application.ExeName)+'pseuwow.exe') then
      begin
        App := ExtractFilePath(Application.ExeName)+'pseuwow.exe';
        pnlTop.Hide;
      end
      else
        pnlTop.Show;
    end;
    IniFile.WriteString('Execute','Application',App);

    //TT: Read Tray Icon, Nice for those of us who more than one session at a time!
    iIcon := IniFile.ReadInteger('Look','Icon',-1);

    if (iIcon = -1) then
      IniFile.WriteInteger('Look','Icon',0);

    SetIcon(iIcon, False);

  finally
    IniFile.UpdateFile;
    IniFile.Free;
  end;
end;

procedure TfrmMain.cbexIconChange(Sender: TObject);
begin
  if Ready then
    SetIcon(cbexIcon.ItemIndex);
end;

procedure TfrmMain.LoadPseuSettings(AConFile : string);
var
  fFile : textfile;
  sBuffer : string;
  sRes : string;
begin
  if FileExists(AConFile) then
  begin
    AssignFile(fFile, AConFile);
    Reset(fFile);

    while not(Eof(fFile)) do
    begin
      sRes := '';

      Readln(fFile, sBuffer);

      if EvaluateProperty(sBuffer, 'charname=', sRes) then
      begin
        txtChar.Caption := sRes;
        Application.Title := sRes + ' - PseuWoW frmMain.Console';
        TrayIcon.Hint := Application.Title;
      end;
    end;
  end;
  CloseFile(fFile);

  comCommand.SetFocus;
end;

end.

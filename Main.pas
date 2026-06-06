//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
//------------------------------------------------------------------------------
// Omni-Rig
//
// Copyright (c) 2003 Alex Shovkoplyas, VE3NEA
//
// ve3nea@dxatlas.com
//------------------------------------------------------------------------------
//
// Shared-port modification:
//   DispatchSlaveAIData  - called from CustRig.RecvEvent (master) to push
//                          AI-mode data into the slave's parser.
//   ApplySharedPort      - called from FormCreate after both Rigs are
//                          configured; wires Rig2.MasterRig when ports match.
//
// MD/FR ordering logic (TS-590SG AI2 mode):
//   TS-590SG sends MD; before FR; on VFO+mode change.
//   On mode-only change, only MD; is sent (no FR; follows).
//   Therefore:
//     - MD; -> buffer the data, start a short timeout (PENDING_MODE_TIMEOUT_MS)
//     - FR; -> if buffer has data, apply it to the VFO determined by FR,
//              then clear buffer; also update VFO state
//     - Timeout fires before FR; -> mode-only change, apply to current VFO
//   FA; and FB; are dispatched directly to Rig1 and Rig2 respectively.
//
//------------------------------------------------------------------------------

unit Main;

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, Dialogs,
  ComCtrls, ExtCtrls, StdCtrls, CustRig, RigObj, RigSett, IniFiles, RigCmds,
  AppEvnts, ComServ, AutoApp, AlStrLst, AlComPrt, Spin, ShellApi, Registry,
  ShlObj, System.Generics.Collections, ByteFuns;

const
  PENDING_MODE_TIMEOUT_MS = 150;  // ms to wait for FR; after MD;

type
  TMainForm = class(TForm)
    Panel1: TPanel;
    OkBtn: TButton;
    CancelBtn: TButton;
    TabControl1: TTabControl;
    ApplicationEvents1: TApplicationEvents;
    Timer1: TTimer;
    Panel2: TPanel;
    Label1: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    Label4: TLabel;
    Label5: TLabel;
    Label6: TLabel;
    Label10: TLabel;
    PortComboBox: TComboBox;
    BaudRateComboBox: TComboBox;
    DataBitsComboBox: TComboBox;
    ParityComboBox: TComboBox;
    StopBitsComboBox: TComboBox;
    RtsComboBox: TComboBox;
    RigComboBox: TComboBox;
    Panel3: TPanel;
    Image1: TImage;
    Label7: TLabel;
    Label8: TLabel;
    Label9: TLabel;
    Label12: TLabel;
    Label14: TLabel;
    PollSpinEdit: TSpinEdit;
    TimeoutSpinEdit: TSpinEdit;
    Label13: TLabel;
    Label15: TLabel;
    Label16: TLabel;
    Label17: TLabel;
    Label18: TLabel;
    Label11: TLabel;
    DtrComboBox: TComboBox;
    Label19: TLabel;
    Label20: TLabel;
    procedure OkBtnClick(Sender: TObject);
    procedure CancelBtnClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure TabControl1Changing(Sender: TObject; var AllowChange: Boolean);
    procedure TabControl1Change(Sender: TObject);
    procedure ApplicationEvents1Message(var Msg: tagMSG; var Handled: Boolean);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormHide(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
    procedure Button1Click(Sender: TObject);
    procedure Label15Click(Sender: TObject);
    procedure Label17Click(Sender: TObject);
  private
    FLog: TFileStream;
    FLogMode: integer;
    { FR/MD pending VFO buffer (FR arrives before MD in AI2 mode) }
    FPendingModeData: TByteArray;    // reserved (not used in FR->MD flow)
    FPendingModeExpiry: TDateTime;   // timeout for MD after FR
    FPendingModeTarget: TRig;        // Rig to receive next MD (set by FR)
    FActiveRig: TRig;                // last Rig that became active (set by FR)
    procedure LoadRigCommands;
    procedure LoadSettings;
    procedure CleanRigTypes;
    procedure SaveSettings;
    procedure ListComPorts;
    procedure ListBaudRates;
    procedure WmTxQueue(var Msg: TMessage); message WM_TXQUEUE;
    procedure WmComStatus(var Msg: TMessage); message WM_COMSTATUS;
    procedure WmComParams(var Msg: TMessage); message WM_COMPARAMS;
    procedure WmComCustom(var Msg: TMessage); message WM_COMCUSTOM;
    procedure OpenLog;
    procedure CloseLog;
    procedure WMQueryEndSession(var Msg: TMessage); message WM_QUERYENDSESSION;
    { Shared-port support }
    procedure ApplySharedPort;
    procedure FlushPendingMode(ATargetRig: TRig);

  public
    RigTypes: TAlStringList;
    Rig1: TRig;
    Rig2: TRig;
    Sett1: TRigSettings;
    Sett2: TRigSettings;
    SetBothModes: boolean;

    procedure ForceForeground;
    function  GetVersion: integer;
    procedure Log(Msg: AnsiString); overload;
    procedure Log(Msg: AnsiString; const Args: array of const); overload;

    { Called from CustRig (master RecvEvent) to push AI data to the slave }
    procedure DispatchSlaveAIData(AMasterRigNumber: integer;
                                  AData: TByteArray);
  end;

function GetCommPortsForOldVersion(lpPortNumbers: PULONG;
  uPortNumbersCount: ULONG; var puPortNumbersFound: ULONG): ULONG;

var
  MainForm: TMainForm;

implementation

{$R *.DFM}

const
  DinMS = 1 / 86400000;  // 1 millisecond as TDateTime

//------------------------------------------------------------------------------
// sys
//------------------------------------------------------------------------------

procedure TMainForm.FormCreate(Sender: TObject);
begin
  if ComServer.StartMode = smAutomation then Application.ShowMainForm := false;
  OpenLog;

  RigTypes := TAlStringList.Create;
  Rig1     := TRig.Create;
  Rig2     := TRig.Create;
  Sett1    := TRigSettings.Create;
  Sett2    := TRigSettings.Create;

  Sett1.Port := 0;
  Sett2.Port := 1;
  Rig1.RigNumber := 1;
  Rig2.RigNumber := 2;

  FPendingModeData   := nil;
  FPendingModeExpiry := 0;
  FPendingModeTarget := nil;
  FActiveRig         := Rig1;  // default: VFO A active

  ListComPorts;
  ListBaudRates;
  LoadRigCommands;
  LoadSettings;

  // Wire shared port BEFORE ToRig so Rig2 does not attempt to open
  // the port itself (ToRig calls Enabled := true internally).
  ApplySharedPort;

  Sett1.ToRig(Rig1);
  Sett2.ToRig(Rig2);

  Panel2.Align := alClient;
  Width := 220;
  Label9.Caption := Format('Version %d.%d',
                            [HiWord(GetVersion), LoWord(GetVersion)]);
  {!}if ComServer <> nil then ComServer.UIInteractive := false;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
var
  i: integer;
begin
  CloseLog;
  Rig1.Free;
  Rig2.Free;
  Sett1.Free;
  Sett2.Free;
  for i := 0 to RigTypes.Count - 1 do RigTypes.Objects[i].Free;
  RigTypes.Free;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := (ComServer = nil) or (ComServer.ObjectCount = 0);
  if not CanClose then Hide;
end;

//------------------------------------------------------------------------------
// shared-port wiring
//------------------------------------------------------------------------------

procedure TMainForm.ApplySharedPort;
begin
  // Reset slave state first (in case called after settings change)
  // If ports differ, ensure Rig2 is independent
  if Sett1.Port <> Sett2.Port then
  begin
    Log('RIG1 and RIG2 use separate COM ports - normal SO2R mode');
    // If Rig2 was previously a slave, restore its own ComPort
    if Rig2.MasterRig <> nil then
    begin
      Rig2.ComPort   := TAlCommPort.Create;
      Rig2.ComPort.OnReceived := nil;  // will be set by ToRig
      Rig2.MasterRig := nil;
    end;
    Exit;
  end;

  // Same port: make Rig2 a slave of Rig1
  // Only wire if not already wired (avoid double-free)
  if Rig2.MasterRig = nil then
  begin
    Log('RIG1/RIG2 share COM%d - VFO A/B split mode activated', [Sett1.Port]);
    Rig2.ComPort.Free;
    Rig2.ComPort   := Rig1.ComPort;
    Rig2.MasterRig := Rig1;
  end;
end;

//------------------------------------------------------------------------------
// MD/FR pending mode buffer
//------------------------------------------------------------------------------

{ Apply buffered MD data to the pending target Rig and clear the buffer }
procedure TMainForm.FlushPendingMode(ATargetRig: TRig);
begin
  if FPendingModeData = nil then Exit;
  Log('Flushing pending MD data to RIG%d', [ATargetRig.RigNumber]);
  ATargetRig.DispatchAIData(FPendingModeData);
  FPendingModeData   := nil;
  FPendingModeExpiry := 0;
  FPendingModeTarget := nil;
  FActiveRig         := Rig1;  // default: VFO A active
end;

//------------------------------------------------------------------------------
// AI-mode data dispatch (shared-port slave)
//------------------------------------------------------------------------------

procedure TMainForm.DispatchSlaveAIData(AMasterRigNumber: integer;
                                        AData: TByteArray);
var
  Header: AnsiString;
  VfoChar: AnsiChar;
begin
  // Only active in shared-port mode
  if Rig2.MasterRig = nil then Exit;
  if AMasterRigNumber <> 1 then Exit;

  if Length(AData) < 2 then Exit;

  Header := AnsiChar(AData[0]) + AnsiChar(AData[1]);

  // --- FA; -> Rig1 only ---
  if Header = 'FA' then
  begin
    Log('Dispatch FA to RIG1');
    Rig1.DispatchAIData(AData);
    Exit;
  end;

  // --- FB; -> Rig2 only ---
  if Header = 'FB' then
  begin
    Log('Dispatch FB to RIG2');
    Rig2.DispatchAIData(AData);
    Exit;
  end;

  // --- FR; -> determine active VFO, set pending target for MD ---
  if Header = 'FR' then
  begin
    if Length(AData) >= 3 then
      VfoChar := AnsiChar(AData[2])
    else
      VfoChar := '0';

    Log('FR received, VFO=%s', [VfoChar]);

    if VfoChar = '0' then
    begin
      // VFO A active: FR -> Rig1, next MD should go to Rig1
      Rig1.DispatchAIData(AData);
      FPendingModeTarget := Rig1;
      FActiveRig         := Rig1;
    end
    else
    begin
      // VFO B active: FR -> Rig2, next MD should go to Rig2
      Rig2.DispatchAIData(AData);
      FPendingModeTarget := Rig2;
      FActiveRig         := Rig2;
    end;
    FPendingModeExpiry := Now + DinMS * PENDING_MODE_TIMEOUT_MS;
    Exit;
  end;

  // --- MD; -> apply to pending target set by FR, or current VFO if no FR ---
  if Header = 'MD' then
  begin
    if FPendingModeTarget <> nil then
    begin
      Log('MD received, applying to RIG%d (from FR target)',
          [FPendingModeTarget.RigNumber]);
      FPendingModeTarget.DispatchAIData(AData);
      FPendingModeTarget := nil;
      FPendingModeExpiry := 0;
    end
    else
    begin
      // No FR preceded this MD: mode-only change on active VFO
      // Apply only to FActiveRig (last VFO that was active via FR)
      Log('MD received without FR, applying to RIG%d (last active)',
          [FActiveRig.RigNumber]);
      FActiveRig.DispatchAIData(AData);
    end;
    FPendingModeData := nil;
    Exit;
  end;

  // --- Other data: pass to both ---
  Rig1.DispatchAIData(AData);
  Rig2.DispatchAIData(AData);
end;

//------------------------------------------------------------------------------
// COM port list
//------------------------------------------------------------------------------

procedure TMainForm.ListComPorts;
var
  i: Integer;
  portNumbers: array[0..50] of ULONG;
  numofports: ULONG;
  portlist: TList<ULONG>;
begin
  ZeroMemory(@portNumbers, SizeOf(portNumbers));
  GetCommPortsForOldVersion(@portNumbers,
    SizeOf(portNumbers) div SizeOf(ULONG), numofports);
  if numofports > 0 then
  begin
    PortComboBox.Clear;
    portlist := TList<ULONG>.Create;
    try
      for i := 0 to numofports - 1 do portlist.Add(portNumbers[i]);
      portlist.Sort;
      for i := 0 to portlist.Count - 1 do
        PortComboBox.Items.Add('COM ' + IntToStr(portlist[i]));
    finally
      portlist.Free;
    end;
  end;
end;

procedure TMainForm.ListBaudRates;
const
  BaudRates: array[0..14] of integer =
    (CBR_110, CBR_300, CBR_600, CBR_1200, CBR_2400, CBR_4800, CBR_9600,
     CBR_14400, CBR_19200, CBR_38400, CBR_56000, CBR_57600, CBR_115200,
     CBR_128000, CBR_256000);
var
  i: integer;
begin
  BaudRateComboBox.Items.Clear;
  for i := 0 to High(BaudRates) do
    BaudRateComboBox.Items.Add(IntToStr(BaudRates[i]));
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
begin
  Rig1.TimerTick;
  Rig2.TimerTick;

  // Timeout check: if FR; arrived but MD; never followed,
  // clear the pending target (VFO switched but mode unchanged).
  if (FPendingModeTarget <> nil) and (Now > FPendingModeExpiry) then
  begin
    Log('FR->MD timeout - no MD followed FR, clearing pending target');
    FPendingModeTarget := nil;
    FPendingModeExpiry := 0;
  end;
end;

//------------------------------------------------------------------------------
// load/save INI
//------------------------------------------------------------------------------

function GetAfreetDataFolder: TFileName;
begin
  SetLength(Result, MAX_PATH);
  SHGetSpecialFolderPath(Application.Handle, @Result[1], CSIDL_APPDATA, true);
  Result := PChar(Result) + '\Afreet\';
end;

function GetIniName: TFileName;
var
  AppName: TFileName;
begin
  if (GetVersion and $FF) < 6
  then
    Result := ChangeFileExt(ParamStr(0), '.ini')
  else
  begin
    Result  := GetAfreetDataFolder + 'Products\';
    AppName := ChangeFileExt(ExtractFileName(ParamStr(0)), '');
    Result  := Result + AppName + '\';
    try ForceDirectories(Result); except end;
    Result  := Result + AppName + '.ini';
  end;
end;

procedure TMainForm.CleanRigTypes;
var
  i: integer;
begin
  for i := 0 to RigTypes.Count - 1 do
    RigTypes[i] := ChangeFileExt(RigTypes[i], '');
  RigTypes.Sort;
  RigTypes.Insert(0, 'NONE');
end;

procedure TMainForm.LoadRigCommands;
var
  Cmds: TRigCommands;
  i: integer;
  Dir: TFileName;
begin
  Dir := ExtractFilePath(ParamStr(0)) + 'Rigs\';
  RigTypes.LoadFileList(Dir + '*.ini');

  for i := RigTypes.Count - 1 downto 0 do
  try
    Log('Loading commands from "%s"', [RigTypes[i]]);
    Cmds := TRigCommands.Create;
    Cmds.FromIni(Dir + RigTypes[i]);
    if Cmds.FLog.Count > 0 then Log('Errors:'#13#10 + Cmds.FLog.Text);
    if Cmds.FLog.Count = 0
    then RigTypes.Objects[i] := Cmds
    else begin RigTypes.Delete(i); Cmds.Free; end;
  except on E: Exception do
    Log(E.Message);
  end;

  CleanRigTypes;
  RigComboBox.Items := RigTypes;
end;

procedure TMainForm.LoadSettings;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(GetIniName);
  try
    Sett1.FromIni(Ini, 'RIG1');
    Log('RIG 1 settings: ' + Sett1.Text);
    Sett2.FromIni(Ini, 'RIG2');
    Log('RIG 2 settings: ' + Sett2.Text);
    SetBothModes := Ini.ReadBool('General', 'SetBothModes', false);
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.SaveSettings;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(GetIniName);
  try
    Sett1.ToIni(Ini, 'RIG1');
    Sett2.ToIni(Ini, 'RIG2');
  finally
    Ini.Free;
  end;
end;

//------------------------------------------------------------------------------
// user interface
//------------------------------------------------------------------------------

procedure TMainForm.FormShow(Sender: TObject);
begin
  TabControl1.TabIndex := 0;
  Panel2.Visible := true;
  Panel3.Visible := false;
  Sett1.FromRig(Rig1);
  Sett2.FromRig(Rig2);
  Sett1.ToControls;
  ComNotifyVisible;
end;

procedure TMainForm.FormHide(Sender: TObject);
begin
  ComNotifyVisible;
end;

procedure TMainForm.TabControl1Changing(Sender: TObject;
  var AllowChange: Boolean);
begin
  case TabControl1.TabIndex of
    0: Sett1.FromControls;
    1: Sett2.FromControls;
  end;
end;

procedure TMainForm.TabControl1Change(Sender: TObject);
begin
  case TabControl1.TabIndex of
    0: Sett1.ToControls;
    1: Sett2.ToControls;
  end;
  Panel2.Visible := TabControl1.TabIndex in [0, 1];
  Panel3.Visible := TabControl1.TabIndex = 2;
end;

procedure TMainForm.OkBtnClick(Sender: TObject);
begin
  case TabControl1.TabIndex of
    0: Sett1.FromControls;
    1: Sett2.FromControls;
  end;
  Log('RIG 1 settings: ' + Sett1.Text);
  Log('RIG 2 settings: ' + Sett2.Text);
  Sett1.ToRig(Rig1);
  Sett2.ToRig(Rig2);
  ApplySharedPort;
  SaveSettings;
  Close;
end;

procedure TMainForm.CancelBtnClick(Sender: TObject);
begin
  Close;
end;

//------------------------------------------------------------------------------
// single instance
//------------------------------------------------------------------------------

procedure TMainForm.ForceForeground;
var
  CurrThreadID, ActiveThreadID: THandle;
begin
  Show;
  CurrThreadID   := GetCurrentThreadId;
  ActiveThreadID := GetWindowThreadProcessId(GetForegroundWindow, nil);
  AttachThreadInput(CurrThreadID, ActiveThreadID, true);
  try SetForegroundWindow(Application.Handle);
  finally AttachThreadInput(CurrThreadID, ActiveThreadID, false); end;
end;

procedure TMainForm.ApplicationEvents1Message(var Msg: tagMSG;
  var Handled: Boolean);
begin
  with Msg do
    Handled := (Message = WM_USER) and (WParam = 73) and (LParam = 88);
  if Handled then ForceForeground;
end;

function TMainForm.GetVersion: integer;
var
  Dummy: DWord;
  Buf: array of Byte;
  Info: PVSFixedFileInfo;
  Len: UINT;
begin
  Result := 0;
  SetLength(Buf, GetFileVersionInfoSize(PChar(ParamStr(0)), Dummy));
  if Length(Buf) = 0 then Exit;
  if not GetFileVersionInfo(PChar(ParamStr(0)), 0, Length(Buf), @Buf[0]) then Exit;
  if not VerQueryValue(@Buf[0], '\', Pointer(Info), Len) then Exit;
  if Len < SizeOf(TVSFixedFileInfo) then Exit;
  Result := Info.dwFileVersionMS;
end;

procedure TMainForm.WmTxQueue(var Msg: TMessage);
begin
  case Msg.WParam of
    1: Rig1.CheckQueue;
    2: Rig2.CheckQueue;
  end;
end;

//------------------------------------------------------------------------------
// debugging log
//------------------------------------------------------------------------------

procedure TMainForm.OpenLog;
begin
  with TIniFile.Create(GetIniName) do
  try FLogMode := ReadInteger('Debug', 'Log', 0); finally Free; end;
  if FLogMode = 0 then Exit;
  try
    FLog := TFileStream.Create(ChangeFileExt(GetIniName, '.log'),
                               fmCreate or fmShareDenyWrite);
  except end;
  Log('Omni-Rig started: Version %d.%d',
      [HiWord(GetVersion), LoWord(GetVersion)]);
end;

procedure TMainForm.CloseLog;
begin
  Log('Omni-Rig stopped');
  FreeAndNil(FLog);
end;

procedure TMainForm.Log(Msg: AnsiString; const Args: array of const);
begin
  Log(Format(Msg, Args));
end;

procedure TMainForm.Log(Msg: AnsiString);
var
  S: AnsiString;
begin
  if (FLog = nil) or (FLogMode = 0) then Exit;
  if FLogMode = 2 then
  begin
    FreeAndNil(FLog);
    try
      FLog := TFileStream.Create(ChangeFileExt(GetIniName, '.log'),
                                 fmOpenReadWrite or fmShareDenyWrite);
      FLog.Seek(0, soFromEnd);
    except end;
  end;
  S := FormatDateTime('hh:nn:ss.zzz ', Now) + Msg;
  if Copy(S, Length(S) - 1, 2) <> #13#10 then S := S + #13#10;
  FLog.WriteBuffer(PAnsiChar(S)^, Length(S));
end;

procedure TMainForm.WmComStatus(var Msg: TMessage);
begin
  DoComNotifyStatus(Msg.WParam);
end;

procedure TMainForm.WmComParams(var Msg: TMessage);
begin
  DoComNotifyParams(Msg.WParam, Msg.LParam);
end;

procedure TMainForm.WmComCustom(var Msg: TMessage);
begin
  DoComNotifyCustom(Msg.WParam, Pointer(Msg.LParam));
end;

procedure TMainForm.Label15Click(Sender: TObject);
begin
  ShellExecute(GetDesktopWindow, 'open',
    'http://www.dxatlas.com/OmniRig', '', '', SW_SHOWNORMAL);
end;

procedure TMainForm.Label17Click(Sender: TObject);
begin
  ShellExecute(Application.Handle, nil,
    'mailto:ve3nea@dxatlas.com?subject=OmniRig', '', '', SW_SHOWNORMAL);
end;

procedure TMainForm.WMQueryEndSession(var Msg: TMessage);
begin
  if ComServer <> nil then ComServer.UIInteractive := false;
  inherited;
end;

var
  H: THandle;

procedure TMainForm.Button1Click(Sender: TObject);
var
  Cfg: tCOMMCONFIG;
begin
  Cfg.dwSize := sizeof(cfg);
  CommConfigDialog('COM1', handle, Cfg);
end;

//------------------------------------------------------------------------------
// GetCommPortsForOldVersion
//------------------------------------------------------------------------------

function GetCommPortsForOldVersion(lpPortNumbers: PULONG;
  uPortNumbersCount: ULONG; var puPortNumbersFound: ULONG): ULONG;
var
  reg: TRegistry;
  slKey: TStringList;
  i: Integer;
  S: string;
  P: PULONG;
  c: ULONG;
  portnum: Integer;
begin
  slKey := TStringList.Create;
  reg   := TRegistry.Create(KEY_READ);
  try
    reg.RootKey := HKEY_LOCAL_MACHINE;
    reg.OpenKey('HARDWARE\DEVICEMAP\SERIALCOMM', False);
    reg.GetValueNames(slKey);
    P := lpPortNumbers;
    c := 0;
    for i := 0 to slKey.Count - 1 do
    begin
      if c >= uPortNumbersCount then Break;
      S := reg.ReadString(slKey[i]);
      S := StringReplace(S, 'COM', '', [rfReplaceAll]);
      portnum := StrToIntDef(S, 0);
      if (portnum >= 1) and (portnum <= 99) then
      begin
        P^ := portnum;
        Inc(P);
        Inc(c);
      end;
    end;
    puPortNumbersFound := c;
  finally
    reg.Free;
    slKey.Free;
  end;
  Result := 0;
end;

initialization
  H := FindWindow('TApplication', 'Omni-Rig');
  if H <> 0 then begin PostMessage(H, WM_USER, 73, 88); Halt; end;
  CreateMutex(nil, False, 'OMNIRIG');

end.

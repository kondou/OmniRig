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
// Shared-port (VFO A/B split) modification
// When two Rig instances share the same physical COM port (MasterRig <> nil
// on the slave), the slave borrows the master's ComPort object and does NOT
// open/close/free it.  All outbound traffic from both instances is serialised
// through a single queue gate in CheckQueue.
//
//------------------------------------------------------------------------------

unit CustRig;

interface

uses
  Windows, Messages, SysUtils, Classes, Forms, AlComPrt, RigCmds, SyncObjs,
  CmdQue, ByteFuns;

const
  MAX_TIMEOUT = 6;
  WM_TXQUEUE  = WM_USER + 1;
  WM_COMSTATUS = WM_USER + 2;
  WM_COMPARAMS = WM_USER + 3;
  WM_COMCUSTOM = WM_USER + 4;
  NEVER  = 999999;
  DinMS  = 1 / 86400000;

type
  TRigCtlStatus = (stNotConfigured, stDisabled, stPortBusy, stNotResponding,
                   stOnLine);

  TCustomRig = class
  private
    FEnabled: boolean;
    FOnline:  boolean;
    FCritSect: TCriticalSection;
    FRigCommands: TRigCommands;
    FNextStatusTime, FDeadLineTime: TDateTime;

    { Shared-port support }
    FMasterRig: TCustomRig;   // nil = independent; non-nil = slave (shares master's ComPort)

    procedure SetEnabled(const Value: boolean);
    function  GetStatus: TRigCtlStatus;
    procedure RecvEvent(Sender: TObject);
    procedure SentEvent(Sender: TObject);
    procedure CtsDsrEvent(Sender: TObject);
    procedure SetFreq(const Value: integer);
    procedure SetFreqA(const Value: integer);
    procedure SetFreqB(const Value: integer);
    procedure SetRitOffset(const Value: integer);
    procedure SetPitch(const Value: integer);
    procedure SetVfo(const Value: TRigParam);
    procedure SetSplit(const Value: TRigParam);
    procedure SetRit(const Value: TRigParam);
    procedure SetXit(const Value: TRigParam);
    procedure SetTx(const Value: TRigParam);
    procedure SetMode(const Value: TRigParam);
    procedure SetRigCommands(const Value: TRigCommands);
    function  GetSplit: TRigParam;

    { Return the ComPort actually used for I/O (master's port when sharing) }
    function  GetActivePort: TAlCommPort;

  protected
    FQueue: TCommandQueue;
    FFreq: integer;
    FFreqA: integer;
    FFreqB: integer;
    FRitOffset: integer;
    FPitch: integer;
    FVfo:   TRigParam;
    FSplit: TRigParam;
    FRit:   TRigParam;
    FXit:   TRigParam;
    FTx:    TRigParam;
    FMode:  TRigParam;

    procedure AddCommands(ACmds: TRigCommandArray; AKind: TCommandKind);
      virtual; abstract;
    procedure ProcessInitReply(ANumber: integer; AData: TByteArray);
      virtual; abstract;
    procedure ProcessStatusReply(ANumber: integer; AData: TByteArray);
      virtual; abstract;
    procedure ProcessWriteReply(AParam: TRigParam; AData: TByteArray);
      virtual; abstract;
    procedure ProcessCustomReply(ASender: Pointer; ACode, AData: TByteArray);
      virtual; abstract;

  public
    RigNumber: integer;
    PollMs, TimeoutMs: integer;
    ComPort: TAlCommPort;     // owned only when MasterRig = nil
    LastWrittenMode: TRigParam;

    constructor Create;
    destructor  Destroy; override;

    procedure AddWriteCommand(AParam: TRigParam; AValue: integer = 0);
      virtual; abstract;
    procedure AddCustomCommand(ASender: Pointer; ACode: TByteArray;
      ALen: integer; AEnd: AnsiString); virtual; abstract;

    procedure Lock;
    procedure UnLock;
    procedure Start;
    procedure Stop;
    procedure TimerTick;
    procedure CheckQueue;
    procedure ForceVfo(const Value: TRigParam);

    { Called by the master's RecvEvent to hand AI-mode data to this slave }
    procedure DispatchAIData(AData: TByteArray);

    function  GetStatusStr: AnsiString;

    { Shared-port: set non-nil on slave AFTER both Rigs are created }
    property MasterRig: TCustomRig read FMasterRig write FMasterRig;

    property RigCommands: TRigCommands read FRigCommands write SetRigCommands;
    property Enabled: boolean read FEnabled write SetEnabled;
    property Status:  TRigCtlStatus read GetStatus;

    property Freq:      integer    read FFreq      write SetFreq;
    property FreqA:     integer    read FFreqA     write SetFreqA;
    property FreqB:     integer    read FFreqB     write SetFreqB;
    property Pitch:     integer    read FPitch     write SetPitch;
    property RitOffset: integer    read FRitOffset write SetRitOffset;
    property Vfo:       TRigParam  read FVfo       write SetVfo;
    property Split:     TRigParam  read GetSplit   write SetSplit;
    property Rit:       TRigParam  read FRit       write SetRit;
    property Xit:       TRigParam  read FXit       write SetXit;
    property Tx:        TRigParam  read FTx        write SetTx;
    property Mode:      TRigParam  read FMode      write SetMode;
  end;

implementation

uses
  Main, AutoApp;

{ TCustomRig }

//------------------------------------------------------------------------------
// system
//------------------------------------------------------------------------------

constructor TCustomRig.Create;
begin
  FCritSect := TCriticalSection.Create;
  FQueue    := TCommandQueue.Create;
  ComPort   := TAlCommPort.Create;
  ComPort.OnReceived := RecvEvent;
  ComPort.OnSent     := SentEvent;
  ComPort.OnCtsDsr   := CtsDsrEvent;
  FMasterRig := nil;
end;

destructor TCustomRig.Destroy;
begin
  Stop;
  // Only free ComPort if we own it (i.e. not a shared slave)
  if FMasterRig = nil then
    ComPort.Free;
  FQueue.Free;
  FCritSect.Free;
  inherited;
end;

//------------------------------------------------------------------------------
// helpers
//------------------------------------------------------------------------------

{ Return the ComPort to use for actual I/O }
function TCustomRig.GetActivePort: TAlCommPort;
begin
  if FMasterRig <> nil then
    Result := FMasterRig.ComPort
  else
    Result := ComPort;
end;

//------------------------------------------------------------------------------
// status
//------------------------------------------------------------------------------

function TCustomRig.GetStatus: TRigCtlStatus;
begin
  Lock;
  try
    if RigCommands = nil then Result := stNotConfigured
    else if not FEnabled   then Result := stDisabled
    else if not GetActivePort.Open then Result := stPortBusy
    else if not FOnline    then Result := stNotResponding
    else Result := stOnLine;
  finally
    UnLock;
  end;
end;

function TCustomRig.GetStatusStr: AnsiString;
const
  StatusStr: array[TRigCtlStatus] of AnsiString =
    ('Rig is not configured', 'Rig is disabled', 'Port is not available',
     'Rig is not responding', 'On-line');
begin
  Result := StatusStr[GetStatus];
end;

//------------------------------------------------------------------------------
// Comm port
//------------------------------------------------------------------------------

procedure TCustomRig.SetEnabled(const Value: boolean);
begin
  if FEnabled = Value then Exit;
  if Value and (RigCommands = nil) then Exit;
  if Value then Start else Stop;
  ComNotifyStatus(RigNumber);
  LastWrittenMode := pmNone;
end;

procedure TCustomRig.Start;
var
  Port: TAlCommPort;
begin
  if RigCommands = nil then Exit;
  MainForm.Log('Starting RIG%d', [RigNumber]);
  Lock;
  try
    if FEnabled then Exit;
    FEnabled := true;
    FQueue.Clear;
    FQueue.Phase    := phIdle;
    FDeadLineTime   := NEVER;
    AddCommands(RigCommands.InitCmd,   ckInit);
    AddCommands(RigCommands.StatusCmd, ckStatus);

    // Only the master (or an independent rig) actually opens the port
    if FMasterRig = nil then
    begin
      Port := ComPort;
      try Port.Open := true; except end;
    end;
    // Slave: port is already open via master – nothing to do here
  finally
    Unlock;
  end;

  Port := GetActivePort;
  if Port.Open then
    CheckQueue
  else
  begin
    if FMasterRig = nil then  // only warn if we were supposed to open it
      MainForm.Log('RIG%d {!} Unable to open port', [RigNumber]);
  end;
end;

procedure TCustomRig.Stop;
begin
  if not FEnabled then Exit;
  MainForm.Log('Stopping RIG%d', [RigNumber]);
  Lock;
  try
    FEnabled := false;
    FOnline  := false;
    FQueue.Clear;
    FQueue.Phase := phIdle;
    // Only the master (or independent rig) closes the port
    if FMasterRig = nil then
      ComPort.Open := false;
  finally
    Unlock;
  end;
end;

procedure TCustomRig.SentEvent(Sender: TObject);
var
  Port: TAlCommPort;
begin
  Port := GetActivePort;
  MainForm.Log('RIG%d data sent, %d bytes in TX buffer', [RigNumber, Port.TxQueue]);
  if Port.TxQueue > 0 then Exit;

  Lock;
  try
    if (not Port.Open) or (FQueue.Phase <> phSending) or (FQueue.Count = 0)
      then Exit;

    if FQueue.CurrentCmd.NeedsReply then
    begin
      FQueue.Phase  := phReceiving;
      FDeadLineTime := Now + DinMS * TimeoutMs;
    end
    else
    begin
      FQueue.Delete(0);
      FQueue.Phase  := phIdle;
      FDeadLineTime := NEVER;
      CheckQueue;
    end;
  finally
    Unlock;
  end;
end;

procedure TCustomRig.RecvEvent(Sender: TObject);
var
  Data: TByteArray;
  i: Integer;
  Port: TAlCommPort;
begin
  Port := GetActivePort;

  Lock;
  try
    Data := nil;

    // AI mode: unsolicited data arrived while idle
    if (FQueue.Phase = phIdle) and (PollMs = 0) then
    begin
      Data := StrToBytes(Port.RxBuffer);
      MainForm.Log('RIG%d transceive received: %s', [RigNumber, BytesToHex(Data)]);

      // Parse against our own StatusCmds.
      // Exception: if sharing a port (MasterRig = nil means we ARE the master),
      // skip MD; processing here - DispatchSlaveAIData handles MD routing
      // to the correct Rig based on the preceding FR; command.
      for i := Low(RigCommands.StatusCmd) to High(RigCommands.StatusCmd) do
      begin
        if (FMasterRig = nil) and (Length(Data) >= 2) and
           (AnsiChar(Data[0]) = 'M') and (AnsiChar(Data[1]) = 'D') then
          Continue;  // skip MD in master's own parser; DispatchSlaveAIData handles it
        Port.RxBlockTerminator := BytesToStr(RigCommands.StatusCmd[i].ReplyEnd);
        ProcessStatusReply(i, Data);
      end;

      // Hand the raw data to any slave rig that shares this port.
      MainForm.DispatchSlaveAIData(RigNumber, Data);

      Exit;
    end;

    if Port.RxBuffer <> '' then Data := StrToBytes(Port.RxBuffer);
    Port.PurgeRx;

    if (FQueue.Phase = phSending) then
    begin
      FQueue.Phase := phReceiving;
      MainForm.Log('RIG%d %d bytes in TX buffer, accepting reply',
                   [RigNumber, Port.TxQueue]);
    end;

    if FQueue.Phase = phReceiving then
      MainForm.Log('RIG%d reply received: %s', [RigNumber, BytesToHex(Data)])
    else
      MainForm.Log('RIG%d {!}unexpected data received: %s',
                   [RigNumber, BytesToHex(Data)]);

    if (not Port.Open) or (FQueue.Phase <> phReceiving) or (FQueue.Count = 0)
      then Exit;

    try
      with FQueue.CurrentCmd do
        case Kind of
          ckInit:   ProcessInitReply(Number, Data);
          ckWrite:  ProcessWriteReply(Param, Data);
          ckStatus: ProcessStatusReply(Number, Data);
          ckCustom: ProcessCustomReply(CustSender, Code, Data);
        end;
    except on E: Exception do
      MainForm.Log('RIG%d {!}Processing reply: %s', [RigNumber, E.Message]);
    end;

    if not FOnline then
    begin
      FOnline := true;
      ComNotifyStatus(RigNumber);
    end;

    FQueue.Delete(0);
    FQueue.Phase  := phIdle;
    FDeadLineTime := NEVER;
    CheckQueue;
  finally
    Unlock;
  end;
end;

{ Called by Main.DispatchSlaveAIData to push AI data into this rig's parser }
procedure TCustomRig.DispatchAIData(AData: TByteArray);
var
  i: Integer;
begin
  if (RigCommands = nil) or (not FEnabled) then Exit;

  Lock;
  try
    MainForm.Log('RIG%d (slave) dispatching AI data: %s',
                 [RigNumber, BytesToHex(AData)]);
    for i := Low(RigCommands.StatusCmd) to High(RigCommands.StatusCmd) do
      ProcessStatusReply(i, AData);

    if not FOnline then
    begin
      FOnline := true;
      ComNotifyStatus(RigNumber);
    end;
  finally
    Unlock;
  end;
end;

procedure TCustomRig.CtsDsrEvent(Sender: TObject);
const
  BoolStr: array[boolean] of string = ('OFF', 'ON');
begin
  MainForm.Log('RIG%d ctrl bits: CTS=%s DSR=%s RLS=%s',
    [RigNumber,
     BoolStr[ComPort.CtsBit],
     BoolStr[ComPort.DsrBit],
     BoolStr[ComPort.RlsdBit]]);
end;

//------------------------------------------------------------------------------
// queue
//------------------------------------------------------------------------------

procedure TCustomRig.Lock;
begin
  FCritSect.Enter;
end;

procedure TCustomRig.UnLock;
begin
  FCritSect.Leave;
end;

procedure TCustomRig.CheckQueue;
var
  S: AnsiString;
  Port: TAlCommPort;
begin
  Port := GetActivePort;

  // Shared-port serialisation:
  // If we are a slave, and the master is currently busy (sending/receiving),
  // back off – the master's SentEvent/RecvEvent will eventually call our
  // CheckQueue again via WM_TXQUEUE.
  if (FMasterRig <> nil) and (FMasterRig.FQueue.Phase <> phIdle) then
    Exit;

  Lock;
  if Port.Open and (FQueue.Phase = phIdle) and (FQueue.Count > 0) then
  try
    if Port.RxBuffer <> '' then
    begin
      MainForm.Log('RIG%d {!}unexpected bytes in RX buffer: %s',
                   [RigNumber, StrToHex(Port.RxBuffer)]);
      Port.PurgeRx;
    end;

    with FQueue[0] do
    begin
      Port.RxBlockSize       := ReplyLength;
      Port.RxBlockTerminator := ReplyEnd;
      if ReplyEnd <> ''     then Port.RxBlockMode := rbTerminator
      else if ReplyLength > 0 then Port.RxBlockMode := rbBlockSize
      else Port.RxBlockMode := rbChar;
    end;

    case FQueue[0].Kind of
      ckInit:   S := 'init';
      ckWrite:  S := FRigCommands.ParamToStr(FQueue[0].Param);
      ckStatus: S := 'status';
      ckCustom: S := 'custom';
    end;
    MainForm.Log('RIG%d sending %s command: %s',
                 [RigNumber, S, BytesToHex(FQueue[0].Code)]);

    FQueue.Phase  := phSending;
    FDeadLineTime := Now + DinMS * TimeoutMs;
    with FQueue[0] do Port.Send(BytesToStr(Code));

    MainForm.Log('RIG%d ComPort.Send called, %d bytes in TX buffer',
                 [RigNumber, Port.TxQueue]);
  finally
    Unlock;
  end;
end;

procedure TCustomRig.TimerTick;
var
  Port: TAlCommPort;
begin
  Port := GetActivePort;

  Lock;
  try
    if not FEnabled then Exit;

    // Only master (or independent) manages port open/close
    if FMasterRig = nil then
      if not Port.Open then try Port.Open := true; except end;

    if PollMs = 0 then Exit;

    if Port.Open and (Now > FNextStatusTime) then
    begin
      if FQueue.HasStatusCommands then
        MainForm.Log('RIG%d Status commands already in queue', [RigNumber])
      else
      begin
        MainForm.Log('RIG%d Adding status commands to queue', [RigNumber]);
        AddCommands(RigCommands.StatusCmd, ckStatus);
      end;
      FNextStatusTime := Now + DinMS * PollMs;
    end;

    if Now > FDeadLineTime then
    begin
      if FOnline then
      begin
        FOnline := false;
        ComNotifyStatus(RigNumber);
        LastWrittenMode := pmNone;
      end;

      case FQueue.Phase of
        phSending:
        begin
          MainForm.Log('RIG%d {!}send timeout, %d bytes still in TX buffer',
                       [RigNumber, Port.TxQueue]);
          Port.PurgeTx;
          FQueue.Phase  := phIdle;
          FDeadLineTime := NEVER;
        end;
        phReceiving:
        begin
          MainForm.Log('RIG%d {!}recv timeout. RX Buffer: "%s"',
                       [RigNumber, StrToHex(Port.RxBuffer)]);
          Port.PurgeRx;
          Port.RxBlockMode := rbChar;
          FQueue.Delete(0);
          FQueue.Phase  := phIdle;
          FDeadLineTime := NEVER;
        end;
      end;
    end;
  finally
    Unlock;
  end;

  CheckQueue;
end;

//------------------------------------------------------------------------------
// set param
//------------------------------------------------------------------------------

procedure TCustomRig.SetRigCommands(const Value: TRigCommands);
begin
  FRigCommands := Value;
  ComNotifyRigType(RigNumber);
end;

procedure TCustomRig.SetFreq(const Value: integer);
begin
  if Enabled then AddWriteCommand(pmFreq, Value);
end;

procedure TCustomRig.SetFreqA(const Value: integer);
begin
  MainForm.Log('Entered SetFreqA');
  if Enabled and (Value <> FFreqA) then AddWriteCommand(pmFreqA, Value);
  MainForm.Log('Exiting SetFreqA');
end;

procedure TCustomRig.SetFreqB(const Value: integer);
begin
  if Enabled and (Value <> FFreqB) then AddWriteCommand(pmFreqB, Value);
end;

procedure TCustomRig.SetMode(const Value: TRigParam);
begin
  if Enabled and (Value in ModeParams) then AddWriteCommand(Value);
end;

procedure TCustomRig.SetPitch(const Value: integer);
begin
  if not Enabled then Exit;
  AddWriteCommand(pmPitch, Value);
  if not (pmPitch in RigCommands.ReadableParams) then FPitch := Value;
end;

procedure TCustomRig.SetRitOffset(const Value: integer);
begin
  if Enabled and (Value <> FRitOffset) then AddWriteCommand(pmRitOffset, Value);
end;

procedure TCustomRig.SetRit(const Value: TRigParam);
begin
  if Enabled and (Value in RitOnParams) and (Value <> FRit) then
    AddWriteCommand(Value);
end;

procedure TCustomRig.SetSplit(const Value: TRigParam);
begin
  if not (Enabled and (Value in SplitParams)) then Exit;
  if (Value in RigCommands.WriteableParams) and (Value <> Split) then
    AddWriteCommand(Value)
  else if Value = pmSplitOn then
  begin
    if Vfo = pmVfoAA then Vfo := pmVfoAB
    else if Vfo = pmVfoBB then Vfo := pmVfoBA;
  end
  else
  begin
    if Vfo = pmVfoAB then Vfo := pmVfoAA
    else if Vfo = pmVfoBA then Vfo := pmVfoBB;
  end
end;

procedure TCustomRig.SetTx(const Value: TRigParam);
begin
  if Enabled and (Value in TxParams) then AddWriteCommand(Value);
end;

procedure TCustomRig.SetVfo(const Value: TRigParam);
begin
  if Enabled and (Value in VfoParams) and (Value <> FVfo) then
    AddWriteCommand(Value);
end;

procedure TCustomRig.ForceVfo(const Value: TRigParam);
begin
  if Enabled then AddWriteCommand(Value);
end;

procedure TCustomRig.SetXit(const Value: TRigParam);
begin
  if Enabled and (Value in XitOnParams) and (Value <> Xit) then
    AddWriteCommand(Value);
end;

function TCustomRig.GetSplit: TRigParam;
begin
  Result := FSplit;
  if Result <> pmNone then Exit;
  if Vfo in [pmVfoAA, pmVfoBB] then Result := pmSplitOff
  else if Vfo in [pmVfoAB, pmVfoBA] then Result := pmSplitOn;
end;

end.

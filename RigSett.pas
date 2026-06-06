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
//   ToRig  - skips ComPort parameter assignment when the rig is a shared slave
//             (MasterRig <> nil), because the port object belongs to the master.
//   FromRig - reads ComPort settings from the master when the rig is a slave,
//             so the UI still shows correct values.
//
//------------------------------------------------------------------------------

unit RigSett;

interface

uses
  SysUtils, Classes, RigObj, IniFiles, Math;

type
  TRigSettings = class
  public
    RigType,
    Port,
    BaudRate,
    DataBits,
    Parity,
    StopBits,
    RtsMode, DtrMode,
    PollMs,
    TimeoutMs: integer;

    procedure FromIni(AIni: TIniFile; ASection: string);
    procedure ToIni(AIni: TIniFile; ASection: string);
    function  Text: string;
    procedure FromControls;
    procedure ToControls;
    procedure FromRig(ARig: TRig);
    procedure ToRig(ARig: TRig);
  end;

implementation

uses
  Main, RigCmds, AlComPrt;

//------------------------------------------------------------------------------
// helper funs
//------------------------------------------------------------------------------

function BaudRateToIndex(Rate: integer): integer;
begin
  Result := Max(0, MainForm.BaudRateComboBox.Items.IndexOf(IntToStr(Rate)));
end;

function IndexToBaudRate(Idx: integer): integer;
begin
  Result := StrToIntDef(MainForm.BaudRateComboBox.Items[Idx], 9600);
end;

//------------------------------------------------------------------------------
// TRigSettings
//------------------------------------------------------------------------------

procedure TRigSettings.FromIni(AIni: TIniFile; ASection: string);
var
  RigName: string;
begin
  RigName  := AIni.ReadString(ASection, 'RigType', 'NONE');
  RigType  := Max(0, MainForm.RigTypes.IndexOf(RigName));
  Port     := AIni.ReadInteger(ASection, 'Port',      Port);
  BaudRate := AIni.ReadInteger(ASection, 'BaudRate',  6);
  DataBits := AIni.ReadInteger(ASection, 'DataBits',  3);
  Parity   := AIni.ReadInteger(ASection, 'Parity',    0);
  StopBits := AIni.ReadInteger(ASection, 'StopBits',  0);
  RtsMode  := AIni.ReadInteger(ASection, 'RtsMode',   1);
  DtrMode  := AIni.ReadInteger(ASection, 'DtrMode',   1);
  PollMs   := AIni.ReadInteger(ASection, 'PollMs',    500);
  TimeoutMs := AIni.ReadInteger(ASection, 'TimeoutMs', 4000);
end;

procedure TRigSettings.ToIni(AIni: TIniFile; ASection: string);
begin
  AIni.EraseSection(ASection);
  AIni.WriteString (ASection, 'RigType',   MainForm.RigTypes[RigType]);
  AIni.WriteInteger(ASection, 'Port',      Port);
  AIni.WriteInteger(ASection, 'BaudRate',  BaudRate);
  AIni.WriteInteger(ASection, 'DataBits',  DataBits);
  AIni.WriteInteger(ASection, 'Parity',    Parity);
  AIni.WriteInteger(ASection, 'StopBits',  StopBits);
  AIni.WriteInteger(ASection, 'RtsMode',   RtsMode);
  AIni.WriteInteger(ASection, 'DtrMode',   DtrMode);
  AIni.WriteInteger(ASection, 'PollMs',    PollMs);
  AIni.WriteInteger(ASection, 'TimeoutMs', TimeoutMs);
end;

procedure TRigSettings.FromControls;
begin
  RigType  := MainForm.RigComboBox.ItemIndex;
  Port     := StrToIntDef(Copy(MainForm.PortComboBox.Text, 5, MAXINT), 1);
  BaudRate := MainForm.BaudRateComboBox.ItemIndex;
  DataBits := MainForm.DataBitsComboBox.ItemIndex;
  Parity   := MainForm.ParityComboBox.ItemIndex;
  StopBits := MainForm.StopBitsComboBox.ItemIndex;
  RtsMode  := MainForm.RtsComboBox.ItemIndex;
  DtrMode  := MainForm.DtrComboBox.ItemIndex;
  PollMs   := MainForm.PollSpinEdit.Value;
  TimeoutMs := MainForm.TimeoutSpinEdit.Value;
end;

procedure TRigSettings.ToControls;
begin
  MainForm.RigComboBox.ItemIndex    := RigType;
  MainForm.PortComboBox.ItemIndex   :=
    Max(0, MainForm.PortComboBox.Items.IndexOf('COM ' + IntToStr(Port)));
  MainForm.BaudRateComboBox.ItemIndex := BaudRate;
  MainForm.DataBitsComboBox.ItemIndex := DataBits;
  MainForm.ParityComboBox.ItemIndex   := Parity;
  MainForm.StopBitsComboBox.ItemIndex := StopBits;
  MainForm.RtsComboBox.ItemIndex      := RtsMode;
  MainForm.DtrComboBox.ItemIndex      := DtrMode;
  MainForm.PollSpinEdit.Value         := PollMs;
  MainForm.TimeoutSpinEdit.Value      := TimeoutMs;
end;

procedure TRigSettings.FromRig(ARig: TRig);
var
  SrcPort: TAlCommPort;
begin
  RigType := MainForm.RigTypes.IndexOfObject(ARig.RigCommands);

  // When the rig is a shared slave its ComPort points to the master's object.
  // Reading port settings from it is fine – they reflect the real hardware.
  SrcPort  := ARig.ComPort;   // same object as master's when sharing

  Port     := SrcPort.Port;
  BaudRate := BaudRateToIndex(SrcPort.BaudRate);
  DataBits := SrcPort.DataBits - 5;
  Parity   := Ord(SrcPort.Parity);
  StopBits := Ord(SrcPort.StopBits);
  RtsMode  := Ord(SrcPort.RtsMode);
  DtrMode  := Ord(SrcPort.DtrMode);
  PollMs   := ARig.PollMs;
  TimeoutMs := ARig.TimeoutMs;
end;

procedure TRigSettings.ToRig(ARig: TRig);
begin
  ARig.Enabled := false;
  try
    ARig.RigCommands := MainForm.RigTypes.Objects[RigType] as TRigCommands;

    // Only configure the COM port when this rig owns it.
    // A shared slave (MasterRig <> nil) must NOT touch the port parameters –
    // the master is responsible for that and may already have it open.
    if ARig.MasterRig = nil then
    begin
      ARig.ComPort.Port     := Port;
      ARig.ComPort.BaudRate := IndexToBaudRate(BaudRate);
      ARig.ComPort.DataBits := DataBits + 5;
      ARig.ComPort.Parity   := TParity(Parity);
      ARig.ComPort.StopBits := TStopBits(StopBits);
      ARig.ComPort.DtrMode  := TFlowControl(DtrMode);
      ARig.ComPort.RtsMode  := TFlowControl(RtsMode);
    end;

    ARig.PollMs    := PollMs;
    ARig.TimeoutMs := TimeoutMs;
  finally
    ARig.Enabled := true;
  end;
end;

function TRigSettings.Text: string;
begin
  Result := Format(
    'Rig=%s|Port=COM%d|Baud=%s|Data=%s|Parity=%s|Stop=%s|RTS=%s|Dtr=%s|Poll=%d|Timeout=%d',
    [
      MainForm.RigComboBox.Items[RigType],
      Port,
      MainForm.BaudRateComboBox.Items[BaudRate],
      MainForm.DataBitsComboBox.Items[DataBits],
      MainForm.ParityComboBox.Items[Parity],
      MainForm.StopBitsComboBox.Items[StopBits],
      MainForm.RtsComboBox.Items[RtsMode],
      MainForm.DtrComboBox.Items[DtrMode],
      PollMs,
      TimeoutMs
    ]);
end;

end.

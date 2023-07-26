program main;

// Socket-based Pascal Language Server
// Copyright 2023 Michael Van Canneyt

// This file is part of Pascal Language Server.

// Pascal Language Server is free software: you can redistribute it
// and/or modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.

// Pascal Language Server is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied warranty
// of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with Pascal Language Server.  If not, see
// <https://www.gnu.org/licenses/>.


{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

uses
  {$IFDEF UNIX}
  cthreads, cwstring,
  {$ENDIF}
  LazLogger,
  Classes, SysUtils, CustApp, IniFiles, LSP.AllCommands,  LSP.Messages,
  LSP.Base, PasLS.Settings, PasLSSock.Config, PasLS.SocketDispatcher;

type

  { TPasLSPSocketServerApp }

  TPasLSPSocketServerApp = class(TCustomApplication)
  Private
    FConfig : TLSPSocketServerConfig;
    procedure ConfigureLSP;
    procedure DoMessageLog(sender: TObject; const Msg: UTF8String);
    function ParseOptions: Boolean;
  protected
    procedure DoRun; override;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    procedure Usage(const aError: String); virtual;
  end;


{ TPasLSPSocketServerApp }

function TPasLSPSocketServerApp.ParseOptions : Boolean;

var
  FN : String;
begin
  Result:=False;
  FN:=GetOptionValue('c','config');
  if FN='' then
    FN:=TLSPSocketServerConfig.DefaultConfigFile;
  FConfig.LoadFromFile(FN);
{$IFDEF UNIX}
  if HasOption('u','unix') then
    FConfig.Unix:=GetOptionValue('u','unix');
{$ENDIF}
  if HasOption('p','port') then
    FConfig.Port:=StrToInt(GetOptionValue('p','port'));
  if HasOption('l','log') then
    FConfig.LogFile:=GetOptionValue('l','log');
  if HasOption('t','threaded') then
    FConfig.Threaded:=True;
  if HasOption('s','single-connect') then
    FConfig.SingleConnect:=True;
  Result:=True;
end;

procedure TPasLSPSocketServerApp.ConfigureLSP;

begin
  TLSPContext.LogFile:=FConfig.LogFile;
  With EnvironmentSettings do
    begin
    pp:=FConfig.Compiler;
    fpcDir:=FConfig.FPCDir;
    lazarusDir:=FConfig.LazarusDir;
    fpcTarget:=FConfig.TargetOS;
    fpcTargetCPU:=FConfig.TargetCPU;
    end;
  TMessageTransport.OnLog:=@DoMessageLog;
end;

procedure TPasLSPSocketServerApp.DoMessageLog(sender: TObject;
  const Msg: UTF8String);
begin
  TLSPContext.Log(Msg);
  if Sender<>Nil then;
end;

procedure TPasLSPSocketServerApp.DoRun;

Const
  ShortOpts = 'hp:u:c:tsl:';
  LongOpts : array of string = ('help','port','unix','config','threaded','single-connect','log:');


var
  ErrorMsg: String;
  Disp : TLSPServerSocketDispatcher;

begin
  Terminate;
  // quick check parameters
  ErrorMsg:=CheckOptions(ShortOpts,LongOpts);
  if (ErrorMsg<>'') or HasOption('h','help') then
    begin
    Usage(ErrorMsg);
    Exit;
    end;
  if not ParseOptions then
    exit;
  ConfigureLSP;
  if FConfig.Port>0 then
    Disp:=TLSPServerTCPSocketDispatcher.Create(FConfig.Port)
  else
    Disp:=TLSPServerUnixSocketDispatcher.Create(FConfig.Unix);
  Try
    Disp.SingleConnect:=FConfig.SingleConnect;
    Disp.InitSocket;
    Disp.RunLoop;
  finally
    Disp.Free;
  end;
end;

constructor TPasLSPSocketServerApp.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  StopOnException:=True;
  FConfig:=TLSPSocketServerConfig.Create;
end;

destructor TPasLSPSocketServerApp.Destroy;
begin
  FConfig.Free;
  inherited Destroy;
end;

procedure TPasLSPSocketServerApp.Usage(const aError : String);
begin
  if aError<>'' then
    Writeln('Error : ',aError);
  Writeln('Usage: ', ExeName, ' [options]');
  Writeln('Where options is one or more of:');
  Writeln('-h  --help           This help message');
  Writeln('-c  --config=FILE    Read configuration from file FILE. Default is to read from ',TLSPSocketServerConfig.DefaultConfigFile);
  Writeln('-l  --log=FILE       Set log file in which to write all log messages');
  Writeln('-p  --port=NNN       Listen on port NNN');
  Writeln('-s  --single-connect Handle one connection and then exit');
  Writeln('-t  --threaded       Use threading for connections.');
  Writeln('-u  --unix=FILE      Listen on unix socket FILE (only on unix-like systems)');
  Writeln('Only one of -p or -u may be specified, if none is specified then the default is to listen on port 9898');
  ExitCode:=Ord(aError<>'')
end;

var
  Application: TPasLSPSocketServerApp;
  Buffer: Array[1..100*1024] of byte;

begin
  Close(Output);
  Assign(Output,GetTempDir(false)+'paslssock-out.log');
  SetTextBuf(Output,Buffer,SizeOf(Buffer));
  Rewrite(output);
  Application:=TPasLSPSocketServerApp.Create(nil);
  Application.Title:='Pascal LSP socket server application';
  Application.Run;
  Application.Free;
end.


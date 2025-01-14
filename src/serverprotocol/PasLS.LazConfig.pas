// Pascal Language Server
// Copyright 2021 Philip Zander

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

unit PasLS.LazConfig;

{$mode objfpc}{$H+}

interface
uses
  SysUtils, Classes, Contnrs, CodeToolManager, CodeToolsConfig, LazUTF8,
  DefineTemplates, FileUtil, LazFileUtils, DOM, XMLRead, LSP.Messages;

Type
  { TPackage }
  TPackage = class;

  TPaths = record
    // Search path for units (OtherUnitFiles)
    UnitPath:         string;
    // Search path for includes (IncludeFiles)
    IncludePath:      string;
    // Additional sources, not passed to compiler (SrcFiles)
    SrcPath:          string;
  end;


  TDependency = record
    // Name of the package, e.g. 'LCLBase'
    Name:             string;

    // Projects may hardcode a path to a package. If a path was hardcoded, Path
    // will contain the expanded path, otherwise will be empty string.
    Path:             string;

    // Whether the hardcoded path should take precedence over a global package
    // of the same name.
    Prefer:           Boolean;

    // Once we have resolved the dependency, we cache a reference to the package
    // here:
    Package:          TPackage;
  end;

  TLazProjectConfig = class;

  TPackage = class
    // Name of the package / project
    //Name:             string;
    // Full filename
    PkgFile:          string;

    // Home directory of the package / project
    Dir:              string;

    // Valid: True if the package was found, False otherwise. If False, this
    // is a dummy object whose only purpose is to prevent us from trying to load
    // a non-existing package multiple times.
    Valid:            Boolean;

    // The search path resolution process involves several stages:
    // 0. Compile all 1st party search paths defined in the package file and
    //    store them in "Paths".
    // 1. Resolve the dependencies (find file name for a given package name)
    // 2. Compile the search paths for all dependencies and add them to our own
    //    search paths (Resolved Paths)
    // 3. Announce the search paths for the package home directory to
    //    CodeToolBoss.

    DidResolveDeps:   Boolean; // True after step 1 is completed
    DidResolvePaths:  Boolean; // True after step 2 is completed
    Configured:       Boolean; // True after step 3 is completed

    Visited:          Boolean; // Temporary flag while guessing dependencies.

    // Absolute 1st-degree search paths for this package
    Paths:            TPaths;

    // List of dependencies of this package
    Dependencies:     array of TDependency;

    // List of packages requiring this package
    // (only 1st degree dependencies)
    RequiredBy:       array of TPackage;

    // Search paths including dependencies
    ResolvedPaths:    TPaths;
  private
    FConfig: TLazProjectConfig;
    function GetAdditionalPaths(SearchPaths: TDomNode; const What: domstring): String;
    procedure LoadDeps(Root: TDomNode);
    procedure LoadFromFile(const aFileName: string);
    procedure LoadPaths(Root: TDomNode);
  Public
    constructor Create(aConfig : TLazProjectConfig);
    procedure Configure;
    procedure ResolveDeps;
    procedure ResolvePaths;
    procedure GuessMissingDependencies;
  end;

  { TLazProjectConfig }

  TLazProjectConfig = class
  Private
    Class var
      PkgNameToPath: TFPStringHashTable;
    // Map Path -> TPackage
      PkgCache:      TFPObjectHashTable;
      _FakeAppName,
      _FakeVendorName: string;
  Private
    FTransport : TMessageTransport;
    FOptions: TCodeToolsOptions;
    function GetPackageOrProject(const FileName: String): TPackage;
    procedure GuessMissingDepsForAllPackages(const Dir: string);
    function IgnoreDirectory(const Dir: string): Boolean;
    procedure LoadAllPackagesUnderPath(const Dir: string);
    function LoadPackageOrProject(const FileName: string): TPackage;
    function LookupGlobalPackage(const Name: String): String;
    procedure PopulateGlobalPackages(const SearchPaths: array of string);
  Protected
    procedure DebugLog(const Msg: string); overload;
    procedure DebugLog(const Fmt: string; Args: array of const); overload;
    Class function MergePaths(Paths: array of string): string;
    class function GetConfigDirForApp(AppName, Vendor: string; Global: Boolean): string; virtual;
    Property Options: TCodeToolsOptions Read FOptions;
  Public
    Class Constructor Init;
    Class Destructor Done;
    Constructor create(aTransport : TMessageTransport; aOptions: TCodeToolsOptions);
    Procedure GuessCodeToolConfig;
    procedure ConfigurePaths(const Dir: string);
    procedure ConfigureSingleProject(const aProjectFile : string);
  end;

procedure GuessCodeToolConfig(aTransport : TMessageTransport; aOptions: TCodeToolsOptions);
procedure ConfigureSingleProject(aTransport : TMessageTransport; const aProjectFile : string);


implementation

uses strutils;

// CodeTools needs to know the paths for the global packages, the FPC source
// files, the path of the compiler and the target architecture.
// Attempt to guess the correct settings from Lazarus config files.
procedure GuessCodeToolConfig(aTransport : TMessageTransport; aOptions: TCodeToolsOptions);

var
  Cfg : TLazProjectConfig;

begin
  Cfg:=TLazProjectConfig.Create(aTransport,aOptions);
  try
    Cfg.GuessCodeToolConfig;
  finally
    Cfg.Free;
  end;
end;

procedure ConfigureSingleProject(aTransport: TMessageTransport;
  const aProjectFile: string);
var
  Cfg : TLazProjectConfig;

begin
  Cfg:=TLazProjectConfig.Create(aTransport,Nil);
  try
    Cfg.ConfigureSingleProject(aProjectFile);
  finally
    Cfg.Free;
  end;
end;


{ TPackage }

constructor TPackage.Create(aConfig: TLazProjectConfig);
begin
  FConfig:=aConfig;
  Valid                  := False;
  Configured             := False;
  DidResolvePaths        := False;
  DidResolveDeps := False;
end;

procedure TPackage.Configure;
var
  Dep:      TDependency;
  OtherSrc: TStringArray;
  OtherDir: string;

  procedure ConfigureSearchPath(const Dir: string);
  var
    DirectoryTemplate,
    IncludeTemplate,
    UnitPathTemplate,
    SrcTemplate:       TDefineTemplate;
    Paths:             TPaths;
  begin
    DirectoryTemplate := TDefineTemplate.Create(
      'Directory', '',
      '', Dir,
      da_Directory
    );

    Paths.UnitPath    := TLazProjectConfig.MergePaths([UnitPathMacro,    ResolvedPaths.UnitPath]);
    Paths.IncludePath := TLazProjectConfig.MergePaths([IncludePathMacro, ResolvedPaths.IncludePath]);
    Paths.SrcPath     := TLazProjectConfig.MergePaths([SrcPathMacro,     ResolvedPaths.SrcPath]);

    FConfig.DebugLog('%s', [Dir]);
    FConfig.DebugLog('  UnitPath:    %s', [Paths.UnitPath]);
    FConfig.DebugLog('  IncludePath: %s', [Paths.IncludePath]);
    FConfig.DebugLog('  SrcPath:     %s', [Paths.SrcPath]);

    UnitPathTemplate := TDefineTemplate.Create(
      'Add to the UnitPath', '',
      UnitPathMacroName, Paths.UnitPath,
      da_DefineRecurse
    );

    IncludeTemplate := TDefineTemplate.Create(
      'Add to the Include path', '',
      IncludePathMacroName, Paths.IncludePath,
      da_DefineRecurse
    );

    SrcTemplate := TDefineTemplate.Create(
      'Add to the Src path', '',
      SrcPathMacroName, Paths.SrcPath,
      da_DefineRecurse
    );

    DirectoryTemplate.AddChild(UnitPathTemplate);
    DirectoryTemplate.AddChild(IncludeTemplate);
    DirectoryTemplate.AddChild(SrcTemplate);

    CodeToolBoss.DefineTree.Add(DirectoryTemplate);
  end;
begin
  if Configured then
    exit;
  Configured := True;

  // Configure search path for package's (or project's) main source directory.
  ConfigureSearchPath(Dir);

  // Configure search path for other listed source directories.
  OtherSrc := Paths.SrcPath.Split([';'], TStringSplitOptions.ExcludeEmpty);
  for OtherDir in OtherSrc do
    ConfigureSearchPath(OtherDir);

  // Recurse
  for Dep in Dependencies do
  begin
    if not Assigned(Dep.Package) then
      continue;
    Dep.Package.Configure;
  end;
end;

function GetFakeAppName: string;
begin
  Result := TLazProjectConfig._FakeAppName;
end;

function GetFakeVendorName: string;
begin
  Result := TLazProjectConfig._FakeVendorName;
end;

procedure TLazProjectConfig.DebugLog(const Msg: string);
begin
  if  (Msg <> '') then
    FTransPort.SendDiagnostic(Msg);
end;

procedure TLazProjectConfig.DebugLog(const Fmt: string; Args: array of const);
var
  s: string;
begin
  s := Format(Fmt, Args) + LineEnding;
  DebugLog(s);
end;

class function TLazProjectConfig.MergePaths(Paths: array of string): string;
var
  i: Integer;
begin
  Result := '';
  for i := low(Paths) to high(Paths) do
  begin
    if (Result <> '') and (Paths[i] <> '') then
      Result := Result + ';' + Paths[i]
    else if (Result = '') and (Paths[i] <> '') then
      Result := Paths[i];
  end;
end;

class function TLazProjectConfig.GetConfigDirForApp(AppName, Vendor: string; Global: Boolean): string;
var
  OldGetAppName:     TGetAppNameEvent;
  OldGetVendorName:  TGetVendorNameEvent;
begin
  _FakeAppName     := AppName;
  _FakeVendorName  := Vendor;
  OldGetAppName    := OnGetApplicationName;
  OldGetVendorName := OnGetVendorName;
  try
    OnGetApplicationName := @GetFakeAppName;
    OnGetVendorName      := @GetFakeVendorName;
    Result               := GetAppConfigDir(Global);
  finally
    OnGetApplicationName := OldGetAppName;
    OnGetVendorName      := OldGetVendorName;
  end;
end;

procedure TLazProjectConfig.PopulateGlobalPackages(const SearchPaths: array of string);

var
  Files:          TStringList;
  Dir, FileName, Name: string;
begin
  Files := TStringList.Create;
  try
    for Dir in SearchPaths do
    begin
      DebugLog('  %s/*.lpk', [Dir]);
      FindAllFiles(Files, Dir, '*.lpk');
    end;

    for FileName in Files do
    begin
      Name := ExtractFileNameOnly(FileName);
      PkgNameToPath[UpperCase(Name)] := FileName;
    end;
    DebugLog('  Found %d packages', [Files.Count]);

  finally
    Files.Free;
  end;
end;

Function TLazProjectConfig.LoadPackageOrProject(const FileName: string): TPackage;

begin
  if Assigned(PkgCache[FileName]) then
    Exit;
  if FileExists(FileName) then
    begin
    DebugLog('Loading %s', [FileName]);
    Result:= TPackage.Create(Self);
    try
      Result.LoadFromFile(FileName);
    except
      Result.Free;
      Raise;
    end;
    PkgCache[FileName] := Result;
    end;
end;

function TPackage.GetAdditionalPaths(SearchPaths: TDomNode; const What: domstring): String;
var
  Node: TDomNode;
  Segments: TStringArray;
  S, Segment, AbsSegment: string;
begin
  Result := '';

  Node := SearchPaths.FindNode(What);
  if Assigned(Node) then
    Node := Node.Attributes.GetNamedItem('Value');
  if not Assigned(Node) then
    Exit;

  S := UTF8Encode(Node.NodeValue);
  Segments := S.Split([';'], TStringSplitOptions.ExcludeEmpty);

  for Segment in Segments do
  begin
    AbsSegment := CreateAbsolutePath(Segment, Dir);
    Result     := Result + ';' + AbsSegment;
  end;
end;

procedure TPackage.LoadPaths(Root : TDomNode);
var
  CompilerOptions, SearchPaths: TDomNode;
begin
  Paths.IncludePath := Dir;
  Paths.UnitPath    := Dir;

  CompilerOptions := Root.FindNode('CompilerOptions');
  if not Assigned(CompilerOptions) then
    Exit;

  SearchPaths := CompilerOptions.FindNode('SearchPaths');
  if not Assigned(SearchPaths) then
    Exit;

  Paths.IncludePath := TLazProjectConfig.MergePaths([
    Paths.IncludePath,
    GetAdditionalPaths(SearchPaths, 'IncludeFiles')
  ]);
  Paths.UnitPath    := TLazProjectConfig.MergePaths([
    Paths.UnitPath,
    GetAdditionalPaths(SearchPaths, 'OtherUnitFiles')
  ]);
  Paths.SrcPath     := GetAdditionalPaths(SearchPaths, 'SrcPath');
end;

procedure TPackage.LoadDeps(Root : TDomNode);

var
  Deps, Item, Name,
  Path, Prefer:      TDomNode;
  Dep:               TDependency;
  i, DepCount:       Integer;
begin
  if UpperCase(ExtractFileExt(PkgFile)) = '.LPK' then
    Deps := Root.FindNode('RequiredPkgs')
  else
    Deps := Root.FindNode('RequiredPackages');

  if not Assigned(Deps) then
    Exit;

  DepCount := 0;
  SetLength(Dependencies, Deps.ChildNodes.Count);

  for i := 0 to Deps.ChildNodes.Count - 1 do
  begin
    Item        := Deps.ChildNodes.Item[i];

    Name        := Item.FindNode('PackageName');
    if not Assigned(Name) then
      continue;

    Name        := Name.Attributes.GetNamedItem('Value');
    if not Assigned(Name) then
      continue;

    Dep.Name    := UTF8Encode(Name.NodeValue);
    Dep.Prefer  := False;
    Dep.Package := nil;
    Dep.Path    := '';

    Path := Item.FindNode('DefaultFilename');

    if Assigned(Path) then
    begin
      Prefer := Path.Attributes.GetNamedItem('Prefer');
      Path   := Path.Attributes.GetNamedItem('Value');

      Dep.Prefer := Assigned(Prefer) and (Prefer.NodeValue = 'True');
      if Assigned(Path) then
        Dep.Path := CreateAbsolutePath(UTF8Encode(Path.NodeValue), Dir);

      //DebugLog('HARDCODED DEP %s in %s', [Dep.Name, Dep.Path]);
      //DebugLog('  Dir: %s, Rel: %s', [Package.Dir, Path.NodeValue]);
    end;

    Dependencies[DepCount] := Dep;
    Inc(DepCount);
  end;
end;


Procedure TPackage.LoadFromFile(const aFileName : string);

var
  Doc:     TXMLDocument;
  Root:    TDomNode;

begin
  Valid := False;
  Dir   := ExtractFilePath(aFileName);
  PkgFile := aFileName;

  try
    try
      ReadXMLFile(doc, afilename);

      Root := Doc.DocumentElement;
      if Root.NodeName <> 'CONFIG' then
        Exit;

      if UpperCase(ExtractFileExt(aFileName)) = '.LPK' then
        Root := Root.FindNode('Package')
      else
        Root := Root.FindNode('ProjectOptions');

      if not Assigned(Root) then
        Exit;

      LoadPaths(Root);
      LoadDeps(Root);

      Valid := True;
    except
      on E:Exception do
      // swallow
      FConfig.DebugLog('Error %s loading %s: %s', [e.ClassName,aFileName, E.Message]);
    end;
  finally
    FreeAndNil(doc);
  end;
end;

function TLazProjectConfig.GetPackageOrProject(const FileName: String): TPackage;
begin
  Result := TPackage(PkgCache[FileName]);
  if not Assigned(Result) then
    Result := LoadPackageOrProject(FileName);
end;

function TLazProjectConfig.LookupGlobalPackage(const Name: String): String;
begin
  Result := PkgNameToPath[UpperCase(Name)];
end;

{ TLazProjectConfig }

class constructor TLazProjectConfig.Init;
begin
  PkgNameToPath := TFPStringHashTable.Create;
  PkgCache      := TFPObjectHashTable.Create;
end;

class destructor TLazProjectConfig.Done;
begin
  FreeAndNil(PkgNameToPath);
  FreeAndNil(PkgCache);
end;

constructor TLazProjectConfig.create(aTransport: TMessageTransport;  aOptions: TCodeToolsOptions);
begin
  FTransport:=aTransport;
  FOptions:=aOptions;
end;


// Resolve the dependencies of Pkg, and then the dependencies of the
// dependencies and so on. Uses global registry and paths locally specified in
// the package/project file (.lpk/.lpi) as a data source.
procedure TPackage.ResolveDeps;
var
  Dep:     ^TDependency;
  DepPath: string;
  i:       integer;
  function IfThen(Cond: Boolean; const s: string): string;
  begin
    if Cond then
      Result := s
    else
      Result := '';
  end;
begin
  if DidResolveDeps then
    exit;

  DidResolveDeps := True;

  for i := low(Dependencies) to high(Dependencies) do
  begin
    Dep := @Dependencies[i];

    DepPath := FConfig.LookupGlobalPackage(Dep^.Name);
    if (Dep^.Prefer) or (DepPath = '') then
      DepPath := Dep^.Path;

    if DepPath = '' then
    begin
      FConfig.DebugLog('  Dependency %s: not found', [Dep^.Name]);
      continue;
    end;

    FConfig.DebugLog(
      '  Dependency: %s -> %s%s',
      [Dep^.Name, DepPath, IfThen(DepPath = Dep^.Path, ' (hardcoded)')]
    );

    Dep^.Package := FConfig.GetPackageOrProject(DepPath);

    // Add ourselves to the RequiredBy list of the dependency.
    SetLength(Dep^.Package.RequiredBy, Length(Dep^.Package.RequiredBy) + 1);
    Dep^.Package.RequiredBy[High(Dep^.Package.RequiredBy)] := Self;

    // Recurse
    Dep^.Package.ResolveDeps;
  end;
end;

// Try to fix missing dependencies.
//
// Consider the following scenario:
//
//   A requires: 
//     - B (found) 
//     - C (NOT found)
//   B requires:
//     - C (found)
//
// In other words, we could not find C for A, but did find C for B. (The
// reason for this might be that B specified a default or preferred path for
// dependency C). In this case we resolve the situation by using B's C also
// for A.
procedure TPackage.GuessMissingDependencies;
var
  Dep: ^TDependency;
  i:   Integer;

  // Breadth-first search for a package of the specified name in the
  // dependencies of Node.
  function GuessDependency(Node: TPackage; DepName: String): TPackage;
  var
    j: integer;
  begin
    Result := nil;

    if Node.Visited then
      exit;

    Node.Visited := True;
    try
      for j := low(Node.Dependencies) to high(Node.Dependencies) do
      begin
        if (UpperCase(DepName) = UpperCase(Node.Dependencies[j].Name)) and
           Assigned(Node.Dependencies[j].Package) then
        begin
          Result := Node.Dependencies[j].Package;
          exit;
        end;
      end;

      // Not found, recurse
      for j := low(Node.RequiredBy) to high(Node.RequiredBy) do
      begin
        Result := GuessDependency(Node.RequiredBy[j], DepName);
        if Assigned(Result) then
          exit;
      end;

    finally
      Node.Visited := False;
    end;
  end;
begin
  for i := low(Dependencies) to high(Dependencies) do
  begin
    Dep := @Dependencies[i];
    if Assigned(Dep^.Package) then
      continue;

    Dep^.Package := GuessDependency(Self, Dep^.Name);
  end;
end;

// Add the search paths of its dependencies to a package.
procedure TPackage.ResolvePaths;
var
  Dep: TDependency;
begin
  if DidResolvePaths then
    exit;

  DidResolvePaths := True;

  ResolvedPaths := Paths;

  for Dep in Dependencies do
  begin
    if not Assigned(Dep.Package) then
      continue;

    // Recurse
    Dep.Package.ResolvePaths;

    ResolvedPaths.IncludePath := TLazProjectConfig.MergePaths([
      ResolvedPaths.IncludePath{,
      Dep.Package.ResolvedPaths.IncludePath}
    ]);
    ResolvedPaths.UnitPath := TLazProjectConfig.MergePaths([
      ResolvedPaths.UnitPath,
      Dep.Package.ResolvedPaths.UnitPath
    ]);
    ResolvedPaths.SrcPath := TLazProjectConfig.MergePaths([
      ResolvedPaths.SrcPath{,
      Dep.Package.ResolvedPaths.SrcPath}
    ]);
  end;
end;

// Add required search paths to package's source directories (and their
// subdirectories).

// Don't load packages from directories with these names...
function TLazProjectConfig.IgnoreDirectory(const Dir: string): Boolean;
var
  DirName: string;
begin
  Dirname := lowercase(ExtractFileName(Dir));
  Result := 
    (DirName = '.git')                              or 
    ((Length(DirName) >= 1) and (DirName[1] = '.')) or
    (DirName = 'backup')                            or 
    (DirName = 'lib')                               or 
    (Pos('.dsym', DirName) > 0)                     or
    (Pos('.app', DirName) > 0);
end;

// Load all packages in a directory and its subdirectories.
procedure TLazProjectConfig.LoadAllPackagesUnderPath(const Dir: string);
var
  Packages,
  SubDirectories:    TStringList;
  i:                 integer;     
  Pkg:               TPackage;
begin
  if IgnoreDirectory(Dir) then
    Exit;

  try
    Packages := FindAllFiles(
      Dir, '*.lpi;*.lpk', False, faAnyFile and not faDirectory
    );

    for i := 0 to Packages.Count - 1 do
    begin
      Pkg := GetPackageOrProject(Packages[i]);
      Pkg.ResolveDeps;
    end;

    // Recurse into child directories

    SubDirectories := FindAllDirectories(Dir, False);
    for i := 0 to SubDirectories.Count - 1 do
      LoadAllPackagesUnderPath(SubDirectories[i]);

  finally
    if Assigned(Packages) then
      FreeAndNil(Packages);
    if Assigned(Packages) then
      FreeAndNil(SubDirectories);
  end;
end;

// Given a directory, fix missing deps for all packages in the directory.
procedure TLazProjectConfig.GuessMissingDepsForAllPackages(const Dir: string);
var
  Packages,
  SubDirectories:    TStringList;
  i:                 integer;
  Pkg:               TPackage;
begin
  if IgnoreDirectory(Dir) then
    Exit;

  try
    Packages := FindAllFiles(
      Dir, '*.lpi;*.lpk', False, faAnyFile and not faDirectory
    );

    for i := 0 to Packages.Count - 1 do
    begin
      Pkg := GetPackageOrProject(Packages[i]);
      Pkg.GuessMissingDependencies;
    end;

    // Recurse into child directories
    SubDirectories := FindAllDirectories(Dir, False);
    for i := 0 to SubDirectories.Count - 1 do
      GuessMissingDepsForAllPackages(SubDirectories[i]);

  finally
    if Assigned(Packages) then
      FreeAndNil(Packages);
    if Assigned(Packages) then
      FreeAndNil(SubDirectories);
  end;
end;

// Use heuristic to add search paths to the directory 'Dir'.
// If there are any projects (.lpi) or packages (.lpk) in the directory, use
// (only) their search paths. Otherwise, inherit the search paths from the
// parent directory ('ParentPaths').
procedure TLazProjectConfig.ConfigurePaths(const Dir: string);
var
  Packages,
  SubDirectories:    TStringList;
  i:                 integer;
  DirectoryTemplate,
  IncludeTemplate,
  UnitPathTemplate : TDefineTemplate;
  Pkg:               TPackage;

begin
  if IgnoreDirectory(Dir) then
    Exit;

  Packages       := nil;
  SubDirectories := nil;
  try
    // 1. Add local files to search path of current directory
    DirectoryTemplate := TDefineTemplate.Create(
      'Directory', '',
      '', Dir,
      da_Directory
    );
    UnitPathTemplate := TDefineTemplate.Create(
      'Add to the UnitPath', '',
      UnitPathMacroName, MergePaths([UnitPathMacro, Dir]),
      da_Define
    );
    IncludeTemplate := TDefineTemplate.Create(
      'Add to the Include path', '',
      IncludePathMacroName, MergePaths([IncludePathMacro, Dir]),
      da_Define
    );
    DirectoryTemplate.AddChild(UnitPathTemplate);
    DirectoryTemplate.AddChild(IncludeTemplate);
    CodeToolBoss.DefineTree.Add(DirectoryTemplate);

    // 2. Load all packages in the current directory and configure their
    //    paths.
    Packages := FindAllFiles(
      Dir, '*.lpi;*.lpk', False, faAnyFile and not faDirectory
    );

    // 2a. Recursively resolve search paths for each package.
    //     (Merge dependencies' search paths into own search path)
    for i := 0 to Packages.Count - 1 do
    begin
      Pkg := GetPackageOrProject(Packages[i]);
      Pkg.ResolvePaths;
    end;

    // 2b. For each package in the dependency tree, apply the package's
    //     resulting search paths from the previous step to the package's source
    //     directories. ("apply" = add to the CodeTools Define Tree)
    for i := 0 to Packages.Count - 1 do
    begin
      Pkg := GetPackageOrProject(Packages[i]);
      Pkg.Configure;
    end;

    // Recurse into child directories
    SubDirectories := FindAllDirectories(Dir, False);
    for i := 0 to SubDirectories.Count - 1 do
      ConfigurePaths(SubDirectories[i]);
  finally
    if Assigned(Packages) then
      FreeAndNil(Packages);
    if Assigned(Packages) then
      FreeAndNil(SubDirectories);
  end;
end;

procedure TLazProjectConfig.ConfigureSingleProject(const aProjectFile: string);

Var
  Pkg : TPackage;
  FN : String;

begin
  try
  FN:=aProjectFile;
  if IndexText(LowerCase(ExtractFileExt(FN)),['.lpi','.lpk'])=-1 then
    begin
    FN:=ChangeFileExt(FN,'.lpi');
    if not FileExists(FN) then
      FN:=ChangeFileExt(FN,'.lpk');
    end;
  if FileExists(FN) then
    begin
    Pkg := GetPackageOrProject(FN);
    Pkg.ResolvePaths;
    Pkg.Configure;
    end;
  except
    On e : Exception do
      DebugLog('Error %s configuring single project "%s": %s',[E.ClassName,aProjectFile,E.Message]);
  end;
end;


procedure TLazProjectConfig.GuessCodeToolConfig;

var
  ConfigDirs:         TStringList;
  Doc:                TXMLDocument;

  Root,
  EnvironmentOptions, 
  FPCConfigs, 
  Item1:              TDomNode;

  LazarusDirectory, 
  FPCSourceDirectory, 
  CompilerFilename, 
  OS, CPU:            string;

  function LoadLazConfig(Path: string): Boolean;
  begin
    Doc    := nil;
    Root   := nil;
    Result := false;
    try
      ReadXMLFile(Doc, Path);
      Root := Doc.DocumentElement;
      if Root.NodeName = 'CONFIG' then
        Result := true;
      DebugLog('Reading config from %s', [Path]);
    except
      on e : Exception do
        DebugLog('Error %s Reading config from %s: %s', [E.ClassName,Path,E.Message]);
      // Swallow
    end;
  end;

  function GetVal(Parent: TDomNode; Ident: string; Attr: string='Value'): string;
  var
    Node, Value: TDomNode;
  begin
    Result := '';
    if Parent = nil then
      exit;
    Node := Parent.FindNode(DOMString(Ident));
    if Node = nil then
      exit;
    Value := Node.Attributes.GetNamedItem(DOMString(Attr));
    if Value = nil then
      exit;
    Result := string(Value.NodeValue);
  end;

Var
  FN:                 string;
  Dir:                string;

begin
  ConfigDirs := TStringList.Create;
  try
    ConfigDirs.Add(GetConfigDirForApp('lazarus', '', False));
    ConfigDirs.Add(GetUserDir + DirectorySeparator + '.lazarus');
    ConfigDirs.Add(GetConfigDirForApp('lazarus', '', True));  ;
    for Dir in ConfigDirs do
    begin
      Doc := nil;
      try
        FN:=Dir + DirectorySeparator + 'environmentoptions.xml';
        if FileExists(FN) and LoadLazConfig(FN) then
        begin
          EnvironmentOptions := Root.FindNode('EnvironmentOptions');
          LazarusDirectory   := GetVal(EnvironmentOptions, 'LazarusDirectory');
          FPCSourceDirectory := GetVal(EnvironmentOptions, 'FPCSourceDirectory');
          CompilerFilename   := GetVal(EnvironmentOptions, 'CompilerFilename');
          if (Options.LazarusSrcDir = '') and (LazarusDirectory <> '') then
            Options.LazarusSrcDir := LazarusDirectory;
          if (Options.FPCSrcDir = '') and (FPCSourceDirectory <> '') then
            Options.FPCSrcDir := FPCSourceDirectory;
          if (Options.FPCPath = '') and (CompilerFilename <> '') then
            Options.FPCPath := CompilerFilename;
        end;
      finally
        FreeAndNil(Doc);
      end;
      try
        if LoadLazConfig(Dir + DirectorySeparator + 'fpcdefines.xml') then
        begin
          FPCConfigs := Root.FindNode('FPCConfigs');
          Item1 := nil;
          if Assigned(FPCConfigs) and (FPCConfigs.ChildNodes.Count > 0) then
            Item1 := FPCConfigs.ChildNodes[0];
          OS  := GetVal(Item1, 'RealCompiler', 'OS');
          CPU := GetVal(Item1, 'RealCompiler', 'CPU');
          if (Options.TargetOS = '') and (OS <> '') then
            Options.TargetOS := OS;
          if (Options.TargetProcessor = '') and (CPU <> '') then
            Options.TargetProcessor := CPU;
        end;
      finally
        FreeAndNil(Doc);
      end;
    end;
  finally
    FreeAndNil(ConfigDirs);
  end;
end;

end.

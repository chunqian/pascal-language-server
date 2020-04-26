// https://microsoft.github.io/language-server-protocol/specifications/specification-3-14/#textDocument_hover

unit hover;

{$mode objfpc}{$H+}

interface

uses
  Classes, URIParser, CodeToolManager, CodeCache, IdentCompletionTool, BasicCodeTools,
  lsp, basic;

type
  
  { THoverResponse }

  THoverResponse = class(TPersistent)
  private
    fContents: TMarkupContent;
    fRange: TRange;
  published
    // The hover's content
    property contents: TMarkupContent read fContents write fContents;

    // An optional range is a range inside a text document
    // that is used to visualize a hover, e.g. by changing the background color.
    property range: TRange read fRange write fRange;
  end;

  { THoverRequest }
  
  THoverRequest = class(specialize TLSPRequest<TTextDocumentPositionParams, THoverResponse>)
    function Process(var Params: TTextDocumentPositionParams): THoverResponse; override;
  end;

implementation

{ THoverRequest }

function THoverRequest.Process(var Params: TTextDocumentPositionParams): THoverResponse;
var
  URI: TURI;
  Code: TCodeBuffer;
  X, Y: Integer;
  Hint: String;
begin with Params do
  begin
    Result := THoverResponse.Create;

    URI := ParseURI(textDocument.uri);
    Code := CodeToolBoss.FindFile(URI.Path + URI.Document);
    X := position.character;
    Y := position.line;
    Hint := CodeToolBoss.FindSmartHint(Code, X + 1, Y + 1);

    Result.contents := TMarkupContent.Create(Hint);
    Result.range := nil;
  end;
end;

initialization
  LSPHandlerManager.RegisterHandler('textDocument/hover', THoverRequest);
end.


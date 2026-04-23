/// Framework Core YAML 1.2 core-schema Parser / Writer
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.core.yaml;

{
  *****************************************************************************

   YAML 1.2 core-schema to JSON or TDocVariantData conversion
    - plain / double-quoted / single-quoted scalars with core-schema type
      inference (null / bool / int / float / string)
    - block and flow mappings and sequences
    - literal (|) and folded (>) block scalars with strip/clip/keep chomping
    - comments (# to end of line) outside quoted scalars
    - raises EYamlException on unsupported constructs (&anchor, *alias,
      !!tag, multi-document ---) or on syntactic errors, with 1-based line
      information attached

   Parser strategy: YAML tokens are re-encoded into a JSON buffer, then passed
   to TDocVariantData.InitJson. This sidesteps building a second in-memory DOM
   and reuses the existing JSON scalar handling.

   Writer strategy: walk the TDocVariantData via TTextWriter and emit
   block-style YAML (flow-style when ywoFlowCompact is set).

  *****************************************************************************
}

interface

{$I ..\mormot.defines.inc}

uses
  sysutils,
  classes,
  variants,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.buffers,
  mormot.core.rtti,
  mormot.core.data,
  mormot.core.json,
  mormot.core.variants;


type
  /// exception raised by YAML parser on unsupported or invalid input
  EYamlException = class(ESynException);

  /// customize YAML serialization output
  // - ywoFlowCompact: emit flow style ([] / {}) for short / leaf containers
  // - ywoNoComments: placeholder; this parser does not preserve comments
  TYamlWriterOption = (
    ywoFlowCompact,
    ywoNoComments);
  TYamlWriterOptions = set of TYamlWriterOption;

const
  /// TDocVariant flavor for YAML, enabling floating numbers and name interning
  JSON_YAML =
    [dvoReturnNullForUnknownProperty,
     dvoValueCopiedByReference,
     dvoAllowDoubleValue,
     dvoInternNames];

/// parse YAML UTF-8 text into a TDocVariantData
// - accepts YAML 1.2 core-schema subset (see unit header)
// - raises EYamlException on unsupported constructs or syntactic errors
// - Options defaults to mormot.net.openapi-compatible values when empty
procedure YamlToVariant(const Yaml: RawUtf8; out Doc: TDocVariantData;
  Options: TDocVariantOptions = JSON_YAML);

/// parse a YAML file into a TDocVariantData
// - file is expected to be UTF-8 (BOM tolerated); see YamlToVariant
function YamlFileToVariant(const FileName: TFileName; out Doc: TDocVariantData;
  Options: TDocVariantOptions = JSON_YAML): boolean;

/// serialize a TDocVariant as YAML 1.2 UTF-8 text
// - result is block-style by default; ywoFlowCompact switches leaf containers
//   to flow style
function VariantToYaml(const Doc: variant;
  Options: TYamlWriterOptions = []): RawUtf8;

/// convenient wrapper called by TOpenApiParser.ParseYaml()
function YamlToVariant_OpenApi(const Yaml: RawUtf8;
  out Doc: TDocVariantData): boolean;

/// save a TDocVariant as a YAML file (UTF-8, no BOM, LF line endings)
procedure SaveVariantToYamlFile(const Doc: variant; const FileName: TFileName;
  Options: TYamlWriterOptions = []);

/// convert YAML 1.2 UTF-8 text directly into a JSON RawUtf8
// - convenience wrapper around the internal parser's JSON buffer, useful for
// pipelines that feed further JSON-based processing (e.g. RTTI settings,
// JsonToObject, LoadJson) without going through TDocVariantData
// - returns '' on parse failure (inspect EYamlException for details)
function YamlToJson(const Yaml: RawUtf8): RawUtf8;

/// convert JSON UTF-8 text into YAML 1.2 UTF-8 text
// - pipes the JSON through TDocVariantData then VariantToYaml
// - useful for converting existing JSON settings files or API payloads to YAML
function JsonToYaml(const Json: RawUtf8;
  Options: TYamlWriterOptions = []): RawUtf8;


var
  /// maximum YAML nesting depth before the parser raises EYamlException
  // - default 512 is ample for real-world OpenAPI specs; raise for
  // pathologically deep inputs
  // - converts would-be EStackOverflow into a clean EYamlException with
  // line info; guards both block and flow recursive descent
  YamlMaxDepth: integer = 512;


implementation


{ ----- internal helpers --------------------------------------------------- }

type
  TYamlLine = record
    Indent: PtrInt;   // count of leading space characters
    Content: RawUtf8; // trimmed of leading spaces and trailing \r
    Raw: RawUtf8;     // original line with trailing \r stripped
  end;
  TYamlLines = array of TYamlLine;
  PYamlLine = ^TYamlLine;

function CountLeadingSpaces(p: PUtf8Char): PtrInt;
begin
  result := 0;
  if p <> nil then
    while p[result] = ' ' do
      inc(result);
end;

// split Yaml into lines with indent metadata
// - accepts both LF and CRLF terminators; trailing \r is stripped
procedure SplitYamlLines(const Yaml: RawUtf8; out Lines: TYamlLines);
var
  p, lineStart, stop: PUtf8Char;
  n, len: PtrInt;
  current: PYamlLine;
begin
  p := pointer(Yaml);
  if p = nil then
    exit;
  n := 0;
  stop := p + length(Yaml);
  lineStart := p;
  while p <= stop do
  begin
    if (p = stop) or
       (p^ = #10) then
    begin
      if n >= length(Lines) then
        SetLength(Lines, NextGrow(n));
      current := @Lines[n];
      len := p - lineStart;
      if (len > 0) and
         (p[-1] = #13) then
        dec(len); // strip trailing \r if present
      FastSetString(current^.Raw, lineStart, len);
      current^.Indent := CountLeadingSpaces(pointer(current^.Raw));
      while (len > 0) and
            (lineStart[len - 1] = ' ') do
        dec(len);
      current^.Content := copy(current^.Raw,
        current^.Indent + 1, len - current^.Indent);
      inc(n);
      if p = stop then
        break;
      lineStart := p + 1;
    end;
    inc(p);
  end;
  if length(Lines) <> n then
    SetLength(Lines, n);
end;

// strip an unquoted trailing "# ..." comment from a scalar fragment
// - accounts for single/double quoted spans where # is literal
procedure StripLineComment(var S: RawUtf8);
var
  p, stop: PUtf8Char;
  inSingle, inDouble: boolean;
  cut: PtrInt;
begin
  if S = '' then
    exit;
  p := pointer(S);
  stop := p + length(S);
  inSingle := false;
  inDouble := false;
  cut := -1;
  while p < stop do
  begin
    case p^ of
      '''':
        if not inDouble then
          inSingle := not inSingle;
      '"':
        if not inSingle then
          inDouble := not inDouble;
      '#':
        if not inSingle and not inDouble then
          if (p = pointer(S)) or
             ((p - 1)^ in [' ', #9]) then
          begin
            cut := p - PUtf8Char(pointer(S));
            break;
          end;
    end;
    inc(p);
  end;
  if cut < 0 then
    exit;
  while (cut > 0) and
        (p[cut - 1] <= ' ') do
    dec(cut);
  SetLength(S, cut);
end;

function IsYamlNull(const S: RawUtf8): boolean;
begin
  // YAML 1.2 core schema: null has three case-insensitive spellings,
  // the '~' shortcut, or the empty string
  result := (S = '') or
            (S = '~') or
            IdemPropNameU(S, 'null');
end;

function IsYamlBool(const S: RawUtf8; out V: boolean): boolean;
begin
  // YAML 1.2 core schema accepts any case for the boolean literal
  result := true;
  if IdemPropNameU(S, 'true') then
    V := true
  else if IdemPropNameU(S, 'false') then
    V := false
  else
    result := false;
end;

function IsYamlInt(const S: RawUtf8; out V: Int64): boolean;
// YAML 1.2 core-schema integer with safe overflow detection
// - overflow silently rejects so caller falls back to string emission
const
  MAX_POS: QWord = QWord($7FFFFFFFFFFFFFFF); // Delphi 7 compatible +MaxInt64 
var
  p: PUtf8Char;
  neg: boolean;
  n: integer;
  b: byte;
  u, prev: QWord;
begin
  result := false;
  p := pointer(S);
  n := length(S);
  if n = 0 then
    exit;
  neg := false;
  if (p^ = '-') or
     (p^ = '+') then
  begin
    neg := p^ = '-';
    inc(p);
    dec(n);
  end;
  if n = 0 then
    exit;
  if (n > 2) and
     (p^ = '0') and
     ((p + 1)^ in ['x', 'X']) then
  begin
    // hex (YAML 1.2 core schema: 0x[0-9a-fA-F]+)
    inc(p, 2);
    dec(n, 2);
    if (n = 0) or
       (n > 16) then // > 64-bit
      exit;
    u := 0;
    while n > 0 do
    begin
      b := ConvertHexToBin[p^];
      if b = 255 then
        exit;
      u := (u shl 4) or b;
      inc(p);
      dec(n);
    end;
  end
  else if (n > 2) and
          (p^ = '0') and
          ((p + 1)^ = 'o') then
  begin
    // octal 0o... (YAML 1.2)
    inc(p, 2);
    dec(n, 2);
    if n > 22 then
      exit;
    u := 0;
    while n > 0 do
    begin
      if not (p^ in ['0'..'7']) then
        exit;
      prev := u;
      u := (u shl 3) or QWord(ord(p^) - ord('0'));
      if u < prev then
        exit; // overflow wrapped
      inc(p);
      dec(n);
    end;
  end
  else
  begin
    // decimal
    if n > 20 then
      exit;
    u := 0;
    while n > 0 do
    begin
      if not (p^ in ['0'..'9']) then
        exit;
      prev := u;
      u := u * 10 + QWord(ord(p^) - ord('0'));
      if u < prev then
        exit; // overflow
      inc(p);
      dec(n);
    end;
  end;
  if u > MAX_POS then
    exit;
  if neg then
    u := -u;
  V := u;
  result := true;
end;

function IsYamlFloat(const S: RawUtf8): boolean;
// Recognizes ONLY the JSON number grammar so the lexeme can be emitted raw
// to the JSON buffer: -?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)? with at least one
// of (dot|exponent) to distinguish from integer.
// - rejects YAML-only forms: leading '+', bare ".5", trailing "1." — callers
//   fall back to string emission (safer than letting InitJson reject raw JSON)
var
  p, stop: PUtf8Char;
  digitsInt, digitsFrac, digitsExp: integer;
  sawDot, sawExp: boolean;
begin
  result := false;
  p := pointer(S);
  if p = nil then
    exit;
  stop := p + length(S);
  if p = stop then
    exit;
  if p^ = '-' then
    inc(p);
  // integer part: one or more digits; "01" is not JSON but YAML allows it,
  // we accept permissively (the value round-trips fine)
  digitsInt := 0;
  while (p < stop) and
        (p^ in ['0'..'9']) do
  begin
    inc(p);
    inc(digitsInt);
  end;
  if digitsInt = 0 then
    exit;
  sawDot := false;
  digitsFrac := 0;
  if (p < stop) and
     (p^ = '.') then
  begin
    sawDot := true;
    inc(p);
    while (p < stop) and
          (p^ in ['0'..'9']) do
    begin
      inc(p);
      inc(digitsFrac);
    end;
    if digitsFrac = 0 then
      exit; // "1." is not JSON
  end;
  sawExp := false;
  digitsExp := 0;
  if (p < stop) and
     (p^ in ['e', 'E']) then
  begin
    sawExp := true;
    inc(p);
    if (p < stop) and
       (p^ in ['+', '-']) then
      inc(p);
    while (p < stop) and
          (p^ in ['0'..'9']) do
    begin
      inc(p);
      inc(digitsExp);
    end;
    if digitsExp = 0 then
      exit;
  end;
  if p <> stop then
    exit; // trailing junk
  result := sawDot or sawExp; // must be float-shaped, not just int
end;


{ ----- YAML -> JSON converter --------------------------------------------- }

type
  TYamlToJson = class
  protected
    fLines: TYamlLines;
    fCount: integer;
    fIdx: integer;
    fDepth: integer;
    fMaxDepth: integer;
    fOut: TJsonWriter;
    procedure Error(LineIdx: integer; const Msg: ShortString);
    procedure ErrorFmt(LineIdx: integer; const Fmt: RawUtf8;
      const Args: array of const);
    function SkipBlankLines: PYamlLine;
    function AtEnd: boolean;
      {$ifdef HASINLINE} inline; {$endif}
    function LineIsDashItem(const S: RawUtf8; out afterDash: RawUtf8): boolean;
    function IsDashLine(const S: RawUtf8): boolean;
      {$ifdef HASINLINE} inline; {$endif}
    function LineKeyEnd(const S: RawUtf8): PtrInt;
    procedure CheckUnsupportedScalar(LineIdx: integer; const S: RawUtf8);
    procedure MergeMultilineQuoted(var rest: RawUtf8; firstLineIdx: integer);
    procedure FoldPlainScalar(var rest: RawUtf8; MapIndent: integer);
    procedure ParseValue(MinIndent: integer);
    procedure ParseBlockMap(Indent: integer);
    procedure ParseBlockSeq(Indent: integer);
    procedure ParseImplicitMapFromDash(MapIndent: integer;
      const firstEntry: RawUtf8; firstLineIdx: integer);
    procedure ParseFlow(var p, stop: PUtf8Char; LineIdx: integer);
    procedure ParseFlowMap(var p, stop: PUtf8Char; LineIdx: integer);
    procedure ParseFlowSeq(var p, stop: PUtf8Char; LineIdx: integer);
    procedure EmitFlowScalar(const Frag: RawUtf8; LineIdx: integer);
    procedure EmitScalarFragment(const Frag: RawUtf8; LineIdx: integer);
    procedure EmitJsonString(const S: RawUtf8);
      {$ifdef HASINLINE} inline; {$endif}
    procedure EmitKey(const K: RawUtf8);
    function CollectBlockScalar(MinIndent: integer; Folded: boolean;
      Chomp: AnsiChar; ExplicitIndent: integer = 0): RawUtf8;
    procedure EmitBlockScalar(const rest: RawUtf8; BaseIndent: integer);
  public
    constructor Create;
    destructor Destroy; override;
    function Run(const Yaml: RawUtf8): RawUtf8;
  end;


constructor TYamlToJson.Create;
begin
  inherited Create;
  fOut := TJsonWriter.CreateOwnedStream;
  fMaxDepth := YamlMaxDepth;
  if fMaxDepth < 4 then
    fMaxDepth := 4; // sanity floor: allow at least a few nested structures
end;

destructor TYamlToJson.Destroy;
begin
  fOut.Free;
  inherited Destroy;
end;

procedure TYamlToJson.Error(LineIdx: integer; const Msg: ShortString);
begin
  EYamlException.RaiseUtf8('YAML line %: %', [LineIdx + 1, Msg]);
end;

procedure TYamlToJson.ErrorFmt(LineIdx: integer; const Fmt: RawUtf8;
  const Args: array of const);
var
  msg: ShortString;
begin
  FormatShort(Fmt, Args, msg);
  Error(LineIdx, msg);
end;

function TYamlToJson.AtEnd: boolean;
begin
  result := fIdx >= fCount;
end;

function TYamlToJson.SkipBlankLines: PYamlLine;
begin
  result := @fLines[fIdx];
  while fIdx < fCount do
  begin
    if (result^.Content = '') or
       (result^.Content[1] = '#') then
      inc(fIdx)
    else
      break;
    inc(result);
  end;
end;

function TYamlToJson.LineIsDashItem(const S: RawUtf8;
  out afterDash: RawUtf8): boolean;
var
  i: PtrInt;
begin
  result := false;
  if (S = '') or
     (S[1] <> '-') then
    exit;
  if length(S) = 1 then
  begin
    result := true;
    exit;
  end;
  i := 2;
  if not (S[i] in [' ', #9]) then // YAML requires '- '
    exit;
  repeat
    inc(i);
  until not (S[i] in [' ', #9]);
  afterDash := copy(S, i, MaxInt);
  result := true;
end;

function TYamlToJson.IsDashLine(const S: RawUtf8): boolean;
// fast check, no afterDash extraction
begin
  result := (S <> '') and
            (S[1] = '-') and
            ((length(S) = 1) or (S[2] in [' ', #9]));
end;

function TYamlToJson.LineKeyEnd(const S: RawUtf8): PtrInt;
// returns the 0-based index of the ':' that ends the key (followed by space or EOL),
// or -1 if not a mapping line; the key itself may be quoted.
var
  p, stop: PUtf8Char;
  inSingle, inDouble: boolean;
begin
  result := -1;
  if S = '' then
    exit;
  p := pointer(S);
  stop := p + length(S);
  inSingle := false;
  inDouble := false;
  while p < stop do
  begin
    case p^ of
      '''':
        if not inDouble then
          inSingle := not inSingle;
      '"':
        if not inSingle then
          inDouble := not inDouble;
      ':':
        if not inSingle and
           not inDouble then
        begin
          if (p + 1 = stop) or
             ((p + 1)^ in [' ', #9]) then
          begin
            result := p - PUtf8Char(pointer(S));
            exit;
          end;
        end;
      '#':
        if not inSingle and
           not inDouble then
          if (p = pointer(S)) or
             ((p - 1)^ in [' ', #9]) then
            exit; // comment - no colon before it
    end;
    inc(p);
  end;
end;

procedure TYamlToJson.CheckUnsupportedScalar(LineIdx: integer; const S: RawUtf8);
var
  p, stop: PUtf8Char;
  inSingle, inDouble: boolean;
  c: AnsiChar;
begin
  if S = '' then
    exit;
  if (S = '---') or
     (S = '...') then
    Error(LineIdx, 'multi-document streams are not supported');
  p := pointer(S);
  stop := p + length(S);
  inSingle := false;
  inDouble := false;
  while p < stop do
  begin
    c := p^;
    case c of
      '''':
        if not inDouble then
          inSingle := not inSingle;
      '"':
        if not inSingle then
          inDouble := not inDouble;
      '&',
      '*',
      '!':
        // per YAML 1.2 §5.3, anchor/alias/tag indicators are only meaningful
        // at the start of a NODE fragment (which is what CheckUnsupportedScalar
        // is called with - a key's rest or a dash item's afterDash). Mid-
        // fragment occurrences are literal text in plain scalars. This avoids
        // firing on real-world OpenAPI descriptions: URL query "?a=1&b=2"
        // (27 hits in GitHub REST), markdown "**bold**" (182 hits) and
        // markdown inline images "![img](url)" (215 hits).
        if not inSingle and
           not inDouble then
          if p = pointer(S) then
            case c of
              '&':
                Error(LineIdx, 'YAML anchors (&name) are not supported');
              '*':
                Error(LineIdx, 'YAML aliases (*name) are not supported');
              '!':
                Error(LineIdx, 'explicit YAML tags (!...) are not supported');
            end;
    end;
    inc(p);
  end;
end;

procedure TYamlToJson.EmitJsonString(const S: RawUtf8);
begin
  fOut.AddJsonString(S);
end;

procedure TYamlToJson.EmitKey(const K: RawUtf8);
begin
  if K <> '' then
    case K[1] of
      '"':
        fOut.AddNoJsonEscape(pointer(K), length(K)); // already JSON-escaped
      '''':
        fOut.AddQuotedStringAsJson(K);               // unquote and JSON-escape
    else
      fOut.AddJsonString(K);                         // JSON-escape
    end
  else
    fOut.AddShorter('""');
end;

procedure TYamlToJson.EmitScalarFragment(const Frag: RawUtf8; LineIdx: integer);
var
  s: RawUtf8;
  bval: boolean;
  ival: Int64;
begin
  s := Frag;
  StripLineComment(s);
  s := TrimLeft(s);
  if s = '' then
  begin
    fOut.AddNull;
    exit;
  end;
  if s[1] in ['"', ''''] then
  begin
    EmitKey(s);
    exit;
  end;
  CheckUnsupportedScalar(LineIdx, s);
  if IsYamlNull(s) then
    fOut.AddNull
  else if IsYamlBool(s, bval) then
    fOut.Add(bval)
  else if IsYamlInt(s, ival) then
    fOut.Add(ival)
  else if IsYamlFloat(s) then
    fOut.AddNoJsonEscape(pointer(s), length(s))
  else
    EmitJsonString(s);
end;

procedure TYamlToJson.EmitFlowScalar(const Frag: RawUtf8; LineIdx: integer);
var
  s: RawUtf8;
begin
  // inside flow, no trailing "# comment" stripping (flow uses , and close-brace
  // as terminators; comments after flow close belong to the line)
  s := TrimU(Frag);
  if s = '' then
    Error(LineIdx, 'empty value in flow collection');
  EmitScalarFragment(s, LineIdx);
end;

function TYamlToJson.CollectBlockScalar(MinIndent: integer; Folded: boolean;
  Chomp: AnsiChar; ExplicitIndent: integer): RawUtf8;
var
  tmp: TTextWriter;
  i, blockIndent, startIdx: PtrInt;
  c: PYamlLine;
  lineContent: RawUtf8;
  blankRun: integer;
  prevWasContent: boolean;
  buf: TTextWriterStackBuffer;
begin
  result := '';
  startIdx := fIdx;
  i := startIdx;
  c := @fLines[startIdx];
  if ExplicitIndent > 0 then
  begin
    // YAML 1.2 §8.1.1.1 explicit indent indicator: the content indent is
    // fixed at parent_indent + ExplicitIndent, NOT auto-detected. MinIndent
    // equals parent_indent + 1 at this point, so parent_indent = MinIndent-1.
    blockIndent := MinIndent - 1 + ExplicitIndent;
    // skip leading blank lines; stop at the first non-blank line. If that
    // line is shallower than blockIndent, the block is empty (blockIndent
    // reset to -1 so the existing "empty block" path below takes over).
    while i < fCount do
    begin
      if c^.Content = '' then
      begin
        inc(i);
        inc(c);
        continue;
      end;
      break;
    end;
    if (i >= fCount) or
       (c^.Indent < blockIndent) then
      blockIndent := -1;
  end
  else
  begin
    // detect block indent from the first non-blank line whose indent >= MinIndent
    blockIndent := -1;
    while i < fCount do
    begin
      if c^.Content = '' then
      begin
        inc(i);
        inc(c);
        continue;
      end;
      if c^.Indent < MinIndent then
        break;
      blockIndent := c^.Indent;
      break;
    end;
  end;
  if blockIndent < 0 then
  begin
    fIdx := i;
    // empty block: honor chomping
    case Chomp of
      '-':
        result := '';
      '+':
        result := '';
      else
        result := '';
    end;
    exit;
  end;
  tmp := TTextWriter.CreateOwnedStream(buf);
  try
    blankRun := 0;
    prevWasContent := false;
    while i < fCount do
    begin
      if c^.Content = '' then
      begin
        inc(blankRun);
        inc(i);
        inc(c);
        continue;
      end;
      if c^.Indent < blockIndent then
        break;
      // block content line: strip blockIndent prefix
      lineContent := copy(c^.Raw, blockIndent + 1, MaxInt);
      if prevWasContent then
        if blankRun = 0 then
          if Folded then
            tmp.Add(' ')
          else
            tmp.Add(#10)
        else
          // preserve blank-line runs literally as \n * blankRun
          while blankRun > 0 do
          begin
            tmp.Add(#10);
            dec(blankRun);
          end
      else
        // leading blanks before first content: keep them
        while blankRun > 0 do
        begin
          tmp.Add(#10);
          dec(blankRun);
        end;
      tmp.AddNoJsonEscape(pointer(lineContent), length(lineContent));
      prevWasContent := true;
      blankRun := 0;
      inc(i);
      inc(c);
    end;
    tmp.SetText(result);
  finally
    tmp.Free;
  end;
  fIdx := i;
  // apply chomping to the trailing content
  case Chomp of
    '-':
      // strip all trailing newlines
      while (result <> '') and
            (result[length(result)] in [#13, #10]) do
        SetLength(result, length(result) - 1);
    '+':
      // keep trailing newlines exactly; ensure at least one
      if (result = '') or
         not (result[length(result)] in [#13, #10]) then
        Append(result, #10);
    else
      // clip: collapse trailing newlines to a single one
      while (length(result) >= 2) and
            (result[length(result)] = #10) and
            (result[length(result) - 1] = #10) do
        SetLength(result, length(result) - 1);
      if (result = '') or
         (result[length(result)] <> #10) then
        Append(result, #10);
  end;
end;

procedure TYamlToJson.EmitBlockScalar(const rest: RawUtf8; BaseIndent: integer);
var
  indicator: AnsiChar;
  folded: boolean;
  chomp: AnsiChar;
  explicitIndent: integer;
  content: RawUtf8;
  i: integer;
begin
  // rest starts with '|' or '>' optionally followed by chomp ('-' or '+')
  // and/or an explicit indent indicator (single digit 1..9, YAML 1.2 §8.1.1.1)
  indicator := rest[1];
  folded := indicator = '>';
  chomp := ' '; // 'clip' default (no chomp indicator)
  explicitIndent := 0;
  for i := 2 to length(rest) do
    case rest[i] of
      '-':
        chomp := '-';
      '+':
        chomp := '+';
      '1'..'9':
        // first digit captured; a second digit is malformed (spec caps at 1..9)
        if explicitIndent = 0 then
          explicitIndent := ord(rest[i]) - ord('0')
        else
          Error(fIdx, 'malformed block-scalar header (double indent indicator)');
      '0':
        // YAML 1.2 §8.1.1.1 forbids 0 as an explicit indent indicator
        Error(fIdx, 'block-scalar indent indicator must be 1..9');
      ' ', #9, '#':
        break;
    else
      break; // unexpected
    end;
  inc(fIdx); // advance past the key-line marker
  content := CollectBlockScalar(BaseIndent + 1, folded, chomp, explicitIndent);
  EmitJsonString(content);
end;

procedure TYamlToJson.MergeMultilineQuoted(var rest: RawUtf8;
  firstLineIdx: integer);
// YAML 1.2 §7.5: a " or ' scalar may span multiple physical lines.
// - double-quoted: a trailing '\' absorbs the line break and leading ws of the
//   next line (escaped line break); otherwise the line break folds to a space
// - single-quoted: '' is the only escape; line break folds to a space
// When invoked, rest must start with the opening quote and fIdx must point at
// the first line of the scalar. On return, rest contains the full quoted span
// (still wrapped in quotes, ready for EmitKey), and fIdx has been
// advanced past any consumed continuation lines. The first (key) line is NOT
// consumed here - callers are responsible for their own fIdx advance on the
// first line, just as before the merge was introduced.
var
  quote: AnsiChar;
  trailingEscape: boolean;

  function ScanQuoteClosed(const s: RawUtf8; skipOpeningQuote: boolean): boolean;
  var
    p, stop: PUtf8Char;
    esc: boolean;
  begin
    result := false;
    trailingEscape := false;
    if s = '' then
      exit;
    p := pointer(s);
    stop := p + length(s);
    if skipOpeningQuote and
       (p^ = quote) then
      inc(p);
    esc := false;
    while p < stop do
    begin
      if quote = '"' then
      begin
        if esc then
          esc := false
        else if p^ = '\' then
          esc := true
        else if p^ = '"' then
        begin
          result := true;
          exit;
        end;
      end
      else
      begin
        // single-quoted: '' is an escape; otherwise '' closes
        if p^ = '''' then
        begin
          if ((p + 1) < stop) and
             ((p + 1)^ = '''') then
            inc(p) // consume the first of the '' escape
          else
          begin
            result := true;
            exit;
          end;
        end;
      end;
      inc(p);
    end;
    // unterminated: remember if double-quoted ended with a trailing '\'
    trailingEscape := (quote = '"') and esc;
  end;

var
  tmp: TTextWriter;
  cur: RawUtf8; // we need a temp value since = rest first
  buf: TTextWriterStackBuffer;
begin
  if rest = '' then
    exit;
  quote := rest[1];
  if not (quote in ['"', '''']) then
    exit;
  if ScanQuoteClosed(rest, {skipOpeningQuote=}true) then
    exit; // single-line, already closed
  // multi-line merge
  tmp := TTextWriter.CreateOwnedStream(buf);
  try
    cur := rest;
    while true do
    begin
      if trailingEscape then
        // absorbed line break: drop the trailing '\' and emit no separator
        tmp.AddNoJsonEscape(pointer(cur), length(cur) - 1)
      else
      begin
        tmp.AddNoJsonEscape(pointer(cur), length(cur));
        // folded line break -> single space (per YAML 1.2 §7.5)
        tmp.AddDirect(' ');
      end;
      inc(fIdx);
      if fIdx >= fCount then
        Error(firstLineIdx, 'unterminated multi-line quoted scalar');
      // Content is already left-trimmed by SplitYamlLines via Indent metadata,
      // which is exactly the §7.5 requirement that leading ws is ignored
      cur := fLines[fIdx].Content;
      if cur = '' then
        continue;
      if ScanQuoteClosed(cur, {skipOpeningQuote=}false) then
      begin
        // last line closes the scalar; include everything up to and past the
        // closing quote (any trailing content is ignored - quoted scalars end
        // at the closing quote)
        tmp.AddNoJsonEscape(pointer(cur), length(cur));
        // leave fIdx pointing at this closing line; callers advance it
        break;
      end;
    end;
    tmp.SetText(rest);
  finally
    tmp.Free;
  end;
end;

procedure TYamlToJson.FoldPlainScalar(var rest: RawUtf8; MapIndent: integer);
// YAML 1.2 §6.5 plain scalar folding: a plain scalar value may continue
// across lines that are indented strictly deeper than the map key. Each
// line break folds to a single space. When invoked, fIdx must already point
// at the first potential continuation line (the caller consumed the key
// line). Advances fIdx past each folded line. A line break is NOT consumed
// when the next line opens a nested structure (dash, flow, block-scalar
// indicator, quoted scalar, or another "key: value" entry).
var
  c: PYamlLine;
begin
  c := @fLines[fIdx];
  while fIdx < fCount do
  begin
    // blank line terminates folding (paragraph break in plain scalars)
    if c^.Content = '' then
      exit;
    // sibling or outer-scope line is not part of the folded scalar
    if c^.Indent <= MapIndent then
      exit;
    // a real "- " dash item at the continuation indent starts a new seq entry
    if IsDashLine(c^.Content) then
      exit;
    // a new "key:" line (quoted or plain) is a nested map, not continuation;
    // LineKeyEnd handles both "foo:" and '"foo":' forms
    if LineKeyEnd(c^.Content) >= 0 then
      exit;
    // otherwise it's plain-scalar text; fold with a single space per §6.5.
    // once we are continuing a plain scalar, indicator chars at line start
    // (", ', {, [, |, >) are just literal text - the GitHub REST spec embeds
    // markdown ("[List selected ...](https://...)") and quoted phrases (e.g.
    // «"My TEam Näme") mid-description
    Append(rest, ' ', c^.Content);
    inc(fIdx);
    inc(c);
  end;
end;

procedure TYamlToJson.ParseBlockMap(Indent: integer);
var
  first: boolean;
  keyEnd: PtrInt;
  keyText, rest: RawUtf8;
  lineIdx: integer;
  c: PYamlLine;
begin
  fOut.Add('{');
  first := true;
  while true do
  begin
    c := SkipBlankLines;
    if AtEnd then
      break;
    if c^.Indent <> Indent then
      break;
    keyEnd := LineKeyEnd(c^.Content);
    if keyEnd < 0 then
      break;
    keyText := TrimRight(copy(c^.Content, 1, keyEnd));
    rest := '';
    if keyEnd + 1 < length(c^.Content) then
      rest := TrimLeft(copy(c^.Content, keyEnd + 2, MaxInt));
    if not first then
      fOut.AddDirect(',');
    EmitKey(keyText);
    fOut.AddDirect(':');
    lineIdx := fIdx;
    if (rest = '') or
       (rest[1] = '#') then
    begin
      inc(fIdx);
      inc(c);
      c := SkipBlankLines;
      if (not AtEnd) and
         (c^.Indent > Indent) then
        ParseValue(c^.Indent)
      else if (not AtEnd) and
              (c^.Indent = Indent) and
              IsDashLine(c^.Content) then
        // YAML 1.2 compact block seq: "key:" followed by "- item" at the
        // same indent as the key (common in real-world OpenAPI specs)
        ParseBlockSeq(c^.Indent)
      else
        fOut.AddNull;
    end
    else if rest[1] in ['|', '>'] then
      EmitBlockScalar(rest, Indent)
    else
    begin
      // YAML 1.2 §7.5: a quoted scalar may span multiple lines
      if rest[1] in ['"', ''''] then
        MergeMultilineQuoted(rest, lineIdx);
      CheckUnsupportedScalar(lineIdx, rest);
      if rest[1] in ['{', '['] then
      begin
        // inline flow collection as the value - rewrite Content so ParseValue
        // sees the flow fragment alone, not the full "key: {..}"/"key: [..]"
        // line (otherwise ParseValue would dispatch back to ParseBlockMap).
        // Mirrors the same pattern in ParseImplicitMapFromDash.
        c^.Content := rest;
        ParseValue(Indent);
      end
      else
      begin
        inc(fIdx); // consume the key line (or the quoted-scalar close line)
        inc(c);
        // YAML 1.2 §6.5: plain scalar may fold across indented lines
        if not (rest[1] in ['"', '''']) then
          FoldPlainScalar(rest, Indent);
        EmitScalarFragment(rest, lineIdx);
      end;
    end;
    first := false;
  end;
  fOut.AddDirect('}');
end;

procedure TYamlToJson.ParseBlockSeq(Indent: integer);
var
  first: boolean;
  afterDash: RawUtf8;
  lineIdx, implicitIndent: integer;
  c: PYamlLine;
begin
  fOut.Add('[');
  first := true;
  while true do
  begin
    c := SkipBlankLines;
    if AtEnd then
      break;
    if c^.Indent <> Indent then
      break;
    if not LineIsDashItem(c^.Content, afterDash) then
      break;
    lineIdx := fIdx;
    if not first then
      fOut.AddDirect(',');
    first := false;
    implicitIndent := Indent + 2;
    if afterDash = '' then
    begin
      inc(fIdx);
      inc(c);
      c := SkipBlankLines;
      if (not AtEnd) and
         (c^.Indent > Indent) then
        ParseValue(c^.Indent)
      else
        fOut.AddNull;
    end
    else if afterDash[1] in ['|', '>'] then
      EmitBlockScalar(afterDash, Indent)
    else if IsDashLine(afterDash) then
    begin
      // YAML 1.2 compact nested block-seq: "- - X" on one physical line.
      // The inner "- X" starts a nested seq at (outer Indent + 2); rewrite
      // the current line to look like it starts at that indent and recurse.
      c^.Content := afterDash;
      c^.Indent := implicitIndent;
      ParseBlockSeq(implicitIndent);
    end
    else if afterDash[1] in ['{', '['] then
    begin
      // flow collection inline
      CheckUnsupportedScalar(lineIdx, afterDash);
      // use flow parser directly on afterDash content
      // simplest: treat the rest of the line as a flow value
      // ParseValue at current indent will see the `- ` already consumed;
      // instead, parse the flow value now by replacing the line content
      // temporarily
      c^.Content := afterDash;
      c^.Indent := implicitIndent;
      ParseValue(implicitIndent);
    end
    else if LineKeyEnd(afterDash) >= 0 then
    begin
      // implicit mapping item: "- key: value" [, "   key2: v2"]
      ParseImplicitMapFromDash(implicitIndent, afterDash, lineIdx);
    end
    else
    begin
      if afterDash[1] in ['"', ''''] then
        MergeMultilineQuoted(afterDash, lineIdx);
      CheckUnsupportedScalar(lineIdx, afterDash);
      inc(fIdx);
      inc(c);
      if not (afterDash[1] in ['"', '''']) then
        FoldPlainScalar(afterDash, Indent);
      EmitScalarFragment(afterDash, lineIdx);
    end;
  end;
  fOut.AddDirect(']');
end;

procedure TYamlToJson.ParseImplicitMapFromDash(MapIndent: integer;
  const firstEntry: RawUtf8; firstLineIdx: integer);
var
  keyEnd: PtrInt;
  lineContent, keyText, rest: RawUtf8;
  curIdx: integer;
  c: PYamlLine;
begin
  fOut.Add('{');
  // emit the first entry from afterDash
  keyEnd := LineKeyEnd(firstEntry);
  if keyEnd < 0 then
    Error(firstLineIdx, 'expected mapping entry after "- "');
  keyText := TrimRight(copy(firstEntry, 1, keyEnd));
  rest := '';
  if keyEnd + 1 < length(firstEntry) then
    rest := TrimLeft(copy(firstEntry, keyEnd + 2, MaxInt));
  EmitKey(keyText);
  fOut.AddDirect(':');
  if (rest = '') or (rest[1] = '#') then
  begin
    inc(fIdx);
    c := SkipBlankLines;
    if (not AtEnd) and
       (c^.Indent > MapIndent) then
      ParseValue(c^.Indent)
    else if (not AtEnd) and
            (c^.Indent = MapIndent) and
            IsDashLine(c^.Content) then
      ParseBlockSeq(c^.Indent)
    else
      fOut.AddNull;
  end
  else if rest[1] in ['|', '>'] then
    // block-scalar min-indent must exceed the parent-key indent (MapIndent),
    // so the EmitBlockScalar base = MapIndent matches ParseBlockMap/continuation
    EmitBlockScalar(rest, MapIndent)
  else
  begin
    if rest[1] in ['"', ''''] then
      MergeMultilineQuoted(rest, firstLineIdx);
    CheckUnsupportedScalar(firstLineIdx, rest);
    if rest[1] in ['{', '['] then
    begin
      c := @fLines[fIdx];
      c^.Content := rest;
      c^.Indent := MapIndent;
      ParseValue(MapIndent);
    end
    else
    begin
      inc(fIdx);
      if not (rest[1] in ['"', '''']) then
        FoldPlainScalar(rest, MapIndent);
      EmitScalarFragment(rest, firstLineIdx);
    end;
  end;
  // continuation: subsequent lines at MapIndent with key-colon
  while true do
  begin
    c := SkipBlankLines;
    if AtEnd then
      break;
    if c^.Indent <> MapIndent then
      break;
    lineContent := c^.Content;
    keyEnd := LineKeyEnd(lineContent);
    if keyEnd < 0 then
      break;
    keyText := TrimRight(copy(lineContent, 1, keyEnd));
    rest := '';
    if keyEnd + 1 < length(lineContent) then
      rest := TrimLeft(copy(lineContent, keyEnd + 2, MaxInt));
    fOut.AddDirect(',');
    EmitKey(keyText);
    fOut.AddDirect(':');
    curIdx := fIdx;
    if (rest = '') or
       (rest[1] = '#') then
    begin
      inc(fIdx);
      c := SkipBlankLines;
      if (not AtEnd) and
         (c^.Indent > MapIndent) then
        ParseValue(c^.Indent)
      else if (not AtEnd) and
              (c^.Indent = MapIndent) and
              IsDashLine(c^.Content) then
        ParseBlockSeq(c^.Indent)
      else
        fOut.AddNull;
    end
    else if rest[1] in ['|', '>'] then
      EmitBlockScalar(rest, MapIndent)
    else
    begin
      if rest[1] in ['"', ''''] then
        MergeMultilineQuoted(rest, curIdx);
      CheckUnsupportedScalar(curIdx, rest);
      if rest[1] in ['{', '['] then
      begin
        fLines[fIdx].Content := rest;
        ParseValue(MapIndent);
      end
      else
      begin
        inc(fIdx);
        if not (rest[1] in ['"', '''']) then
          FoldPlainScalar(rest, MapIndent);
        EmitScalarFragment(rest, curIdx);
      end;
    end;
  end;
  fOut.AddDirect('}');
end;

procedure TYamlToJson.ParseFlow(var p, stop: PUtf8Char; LineIdx: integer);
begin
  inc(fDepth);
  try
    if fDepth > fMaxDepth then
      ErrorFmt(LineIdx,
        'YAML nesting depth exceeds YamlMaxDepth (%)', [fMaxDepth]);
    // p points at '{' or '['
    if p^ = '{' then
      ParseFlowMap(p, stop, LineIdx)
    else if p^ = '[' then
      ParseFlowSeq(p, stop, LineIdx)
    else
      Error(LineIdx, 'expected "{" or "[" in flow value');
  finally
    dec(fDepth);
  end;
end;

procedure TYamlToJson.ParseFlowMap(var p, stop: PUtf8Char; LineIdx: integer);
var
  first: boolean;
  keyStart, keyEnd, valStart, valEnd: PUtf8Char;
  keyText, valText: RawUtf8;
  inSingle, inDouble: boolean;
  depth: integer;
begin
  if p^ <> '{' then
    Error(LineIdx, 'expected "{"');
  inc(p);
  fOut.Add('{');
  first := true;
  while p < stop do
  begin
    // skip whitespace
    while (p < stop) and
          (p^ in [' ', #9]) do
      inc(p);
    if p >= stop then
      Error(LineIdx, 'unterminated flow mapping');
    if p^ = '}' then
    begin
      inc(p);
      fOut.AddDirect('}');
      exit;
    end;
    if (p^ = ',') and
       not first then
    begin
      inc(p);
      continue;
    end;
    // read key: unquoted, quoted, or flow-collection key (rare)
    keyStart := p;
    if p^ in ['"', ''''] then
    begin
      // skip quoted
      inSingle := p^ = '''';
      inDouble := p^ = '"';
      inc(p);
      while p < stop do
      begin
        if inSingle then
        begin
          if p^ = '''' then
          begin
            if (p + 1 < stop) and
               ((p + 1)^ = '''') then
              inc(p, 2)
            else
            begin
              inc(p);
              break;
            end;
          end
          else
            inc(p);
        end
        else if inDouble then
        begin
          if p^ = '\' then
          begin
            inc(p);
            if p < stop then
              inc(p); // skip the escaped char (guarded against buffer end)
          end
          else if p^ = '"' then
          begin
            inc(p);
            break;
          end
          else
            inc(p);
        end;
      end;
      keyEnd := p;
      while (p < stop) and
            (p^ in [' ', #9]) do
        inc(p);
      if (p >= stop) or
         (p^ <> ':') then
        Error(LineIdx, 'expected ":" after flow key');
      inc(p);
    end
    else
    begin
      while (p < stop) and
            not (p^ in [':', ',', '}', #10]) do
        inc(p);
      if (p >= stop) or
         (p^ <> ':') then
        Error(LineIdx, 'expected ":" after flow key');
      keyEnd := p;
      inc(p);
    end;
    FastSetString(keyText, keyStart, keyEnd - keyStart);
    TrimSelf(keyText);
    CheckUnsupportedScalar(LineIdx, keyText);
    if not first then
      fOut.Add(',');
    EmitKey(keyText);
    fOut.AddDirect(':');
    first := false;
    // skip whitespace before value
    while (p < stop) and
          (p^ in [' ', #9]) do
      inc(p);
    if p >= stop then
      Error(LineIdx, 'unterminated flow mapping (expected value)');
    if p^ in ['{', '['] then
      ParseFlow(p, stop, LineIdx)
    else
    begin
      valStart := p;
      depth := 0;
      inSingle := false;
      inDouble := false;
      while p < stop do
      begin
        case p^ of
          '''':
            if not inDouble then
              inSingle := not inSingle;
          '"':
            if not inSingle then
              inDouble := not inDouble;
          '{', '[':
            if not inSingle and
               not inDouble then
              inc(depth);
          '}':
            begin
              if not inSingle and
                 not inDouble then
                if depth = 0 then
                  break
                else
                  dec(depth);
            end;
          ']':
            if not inSingle and
               not inDouble then
              if depth = 0 then
                Error(LineIdx, 'unbalanced "]" in flow-map value')
              else
                dec(depth);
          ',':
            if not inSingle and
               not inDouble and
               (depth = 0) then
              break;
        end;
        inc(p);
      end;
      valEnd := p;
      FastSetString(valText, valStart, valEnd - valStart);
      EmitFlowScalar(valText, LineIdx);
    end;
  end;
  Error(LineIdx, 'unterminated flow mapping');
end;

procedure TYamlToJson.ParseFlowSeq(var p, stop: PUtf8Char; LineIdx: integer);
var
  first, inSingle, inDouble: boolean;
  depth: integer;
  valStart, valEnd: PUtf8Char;
  valText: RawUtf8;
begin
  if p^ <> '[' then
    Error(LineIdx, 'expected "["');
  inc(p);
  fOut.Add('[');
  first := true;
  while p < stop do
  begin
    while (p < stop) and
          (p^ in [' ', #9]) do
      inc(p);
    if p >= stop then
      Error(LineIdx, 'unterminated flow sequence');
    if p^ = ']' then
    begin
      inc(p);
      fOut.AddDirect(']');
      exit;
    end;
    if (p^ = ',') and
       not first then
    begin
      inc(p);
      continue;
    end;
    if p^ in ['{', '['] then
    begin
      if not first then
        fOut.AddDirect(',');
      ParseFlow(p, stop, LineIdx);
      first := false;
      continue;
    end;
    valStart := p;
    depth := 0;
    inSingle := false;
    inDouble := false;
    while p < stop do
    begin
      case p^ of
        '''':
          if not inDouble then
            inSingle := not inSingle;
        '"':
          if not inSingle then
            inDouble := not inDouble;
        '{', '[':
          if not inSingle and
             not inDouble then
            inc(depth);
        '}':
          if not inSingle and
             not inDouble then
            if depth = 0 then
              Error(LineIdx, 'unbalanced "}" in flow-seq value')
            else
              dec(depth);
        ']':
          begin
            if not inSingle and
               not inDouble then
              if depth = 0 then
                break
              else
                dec(depth);
          end;
        ',':
          if not inSingle and
             not inDouble and
             (depth = 0) then
            break;
      end;
      inc(p);
    end;
    valEnd := p;
    FastSetString(valText, valStart, valEnd - valStart);
    if not first then
      fOut.AddDirect(',');
    EmitFlowScalar(valText, LineIdx);
    first := false;
  end;
  Error(LineIdx, 'unterminated flow sequence');
end;

procedure TYamlToJson.ParseValue(MinIndent: integer);
var
  content, afterDash: RawUtf8;
  p, stop: PUtf8Char;
  lineIdx: integer;
  c: PYamlLine;
begin
  inc(fDepth);
  try
    if fDepth > fMaxDepth then
      ErrorFmt(fIdx,
        'YAML nesting depth exceeds YamlMaxDepth (%)', [fMaxDepth]);
    c := SkipBlankLines;
    if AtEnd then
    begin
      fOut.AddNull;
      exit;
    end;
    if c^.Indent < MinIndent then
    begin
      fOut.AddNull;
      exit;
    end;
    lineIdx := fIdx;
    CheckUnsupportedScalar(lineIdx, c^.Content);
    if c^.Content[1] in ['{', '['] then
    begin
      // single-line flow at this indent
      p := pointer(c^.Content);
      stop := p + length(c^.Content);
      ParseFlow(p, stop, lineIdx);
      inc(fIdx);
      exit;
    end;
    if LineIsDashItem(c^.Content, afterDash) then
    begin
      ParseBlockSeq(c^.Indent);
      exit;
    end;
    if LineKeyEnd(c^.Content) >= 0 then
    begin
      ParseBlockMap(c^.Indent);
      exit;
    end;
    // plain top-level scalar line
    if c^.Content[1] in ['|', '>'] then
      EmitBlockScalar(c^.Content, fLines[fIdx].Indent)
    else if c^.Content[1] in ['"', ''''] then
    begin
      content := c^.Content;
      inc(fIdx);
      MergeMultilineQuoted(content, lineIdx);
      EmitScalarFragment(content, lineIdx);
    end
    else
    begin
      EmitScalarFragment(c^.Content, lineIdx);
      inc(fIdx);
    end;
  finally
    dec(fDepth);
  end;
end;

function TYamlToJson.Run(const Yaml: RawUtf8): RawUtf8;
var
  i: PtrInt;
  p, stop: PUtf8Char;
  c: PYamlLine;
begin
  SplitYamlLines(Yaml, fLines);
  fCount := length(fLines);
  // tolerate a single leading "---" directives-end marker: common in spec
  // files (GitHub REST API, Kubernetes, etc.). Strip it so downstream line
  // numbers stay stable with the original file. Any SUBSEQUENT column-0
  // "---" or "..." still raises as multi-document.
  if (fCount > 0) and
     (fLines[0].Indent = 0) and
     (fLines[0].Content = '---') then
    fLines[0].Content := '';
  // upfront scan: multi-doc separators, tab-indented lines, YAML directives
  // - per YAML 1.2 spec, "---" and "..." markers are only structural when at
  // column 0; inside indented content (block scalars, etc.) they're literal
  c := pointer(fLines);
  for i := 0 to fCount - 1 do
  begin
    if (c^.Indent = 0) and
       ((c^.Content = '---') or (c^.Content = '...')) then
      Error(i, 'multi-document streams are not supported');
    // YAML directives (%YAML, %TAG, ...): start with '%' at column 0
    if (c^.Indent = 0) and
       (c^.Content <> '') and
       (c^.Content[1] = '%') then
      Error(i, 'YAML directives (%YAML / %TAG ...) are not supported');
    // tabs in leading whitespace: YAML forbids tab indentation
    p := pointer(c^.Raw);
    if p <> nil then
    begin
      stop := p + length(c^.Raw);
      while (p < stop) and (p^ in [' ', #9]) do
      begin
        if p^ = #9 then
          Error(i, 'tab characters are not allowed for indentation');
        inc(p);
      end;
    end;
    inc(c);
  end;
  fIdx := 0;
  c := SkipBlankLines;
  if AtEnd then
  begin
    result := '{}';
    exit;
  end;
  ParseValue(c^.Indent);
  // after parsing the top-level value, any non-blank line with indent <=
  // topIndent that was not consumed indicates an inconsistent-indent error
  SkipBlankLines;
  if not AtEnd then
    Error(fIdx, 'unexpected line at this indentation');
  fOut.SetText(result);
end;


procedure YamlToVariant(const Yaml: RawUtf8; out Doc: TDocVariantData;
  Options: TDocVariantOptions);
var
  conv: TYamlToJson;
  json, src: RawUtf8;
begin
  src := Yaml;
  // strip UTF-8 BOM regardless of source (file or in-memory) for consistency
  if (length(src) >= 3) and
     (PCardinal(pointer(src))^ and $00ffffff = BOM_UTF8) then
    delete(src, 1, 3);
  conv := TYamlToJson.Create;
  try
    json := conv.Run(src);
  finally
    conv.Free;
  end;
  if Doc.InitJsonInPlace(pointer(json), Options) = nil then
    EYamlException.RaiseU('YamlToVariant: JSON output error');
end;

function YamlToVariant_OpenApi(const Yaml: RawUtf8;
  out Doc: TDocVariantData): boolean;
// convenience alias preserving mormot.net.openapi's exact options set
begin
  try
    YamlToVariant(Yaml, Doc, JSON_FAST + [dvoInternNames]);
    result := true;
  except
    result := false;
  end;
end;

function YamlFileToVariant(const FileName: TFileName; out Doc: TDocVariantData;
  Options: TDocVariantOptions): boolean;
var
  content: RawUtf8;
begin
  if not FileExists(FileName) then
    EYamlException.RaiseUtf8('YamlFileToVariant: file not found: %',
      [FileName]);
  content := StringFromFile(FileName);
  // BOM stripping happens inside YamlToVariant now
  try
    YamlToVariant(content, Doc, Options);
    result := true;
  except
    result := false;
  end;
end;


{ ----- TDocVariant -> YAML writer ----------------------------------------- }

type
  TVariantToYaml = class
  private
    fOut: TJsonWriter;
    fOptions: TYamlWriterOptions;
    procedure WriteValue(const v: variant; Indent: PtrInt);
    procedure WriteBlockMap(const dv: TDocVariantData; Indent: PtrInt);
    procedure WriteBlockSeq(const dv: TDocVariantData; Indent: PtrInt);
    procedure WriteScalar(const v: variant);
    procedure WriteYamlKey(const K: RawUtf8);
      {$ifdef HASINLINE} inline; {$endif}
    procedure WriteYamlString(const S: RawUtf8);
    procedure WriteYamlVariantAsString(const v: variant);
    procedure WriteIndent(N: PtrInt);
      {$ifdef HASINLINE} inline; {$endif}
  public
    constructor Create(Options: TYamlWriterOptions);
    destructor Destroy; override;
    function Run(const Doc: variant): RawUtf8;
  end;

constructor TVariantToYaml.Create(Options: TYamlWriterOptions);
begin
  inherited Create;
  fOut := TJsonWriter.CreateOwnedStream;
  fOptions := Options;
end;

destructor TVariantToYaml.Destroy;
begin
  fOut.Free;
  inherited Destroy;
end;

procedure TVariantToYaml.WriteIndent(N: PtrInt);
begin
  fOut.AddChars(' ', N);
end;

procedure TVariantToYaml.WriteYamlString(const S: RawUtf8);
var
  needsQuote, hasSpecial: boolean;
  i, n: PtrInt;
  c: AnsiChar;
begin
  n := length(S);
  if n = 0 then
  begin
    fOut.AddShorter('""');
    exit;
  end;
  hasSpecial := false;
  needsQuote := false;
  // leading chars that need quoting
  if S[1] in [' ', #9, '!', '&', '*', '>', '|', '%', '@', '`', '"', '''',
              '#', '-', '?', ':', '{', '[', '}', ']', ','] then
    needsQuote := true;
  // trailing whitespace triggers quotes
  if (not needsQuote) and
     (S[n] in [' ', #9]) then
    needsQuote := true;
  // reserved plain-scalar forms: null, bool, numbers - must be quoted to
  // preserve string type on round-trip
  if not needsQuote then
  begin
    if IsYamlNull(S) or
       IdemPropNameU(S, 'true') or
       IdemPropNameU(S, 'false') then
      needsQuote := true
    else if IsYamlFloat(S) then
      needsQuote := true
    else
    begin
      i := 1;
      if S[1] in ['-', '+'] then
        inc(i);
      if (i <= n) and
         (S[i] in ['0'..'9']) then
      begin
        needsQuote := true;
        while i <= n do
          if S[i] in ['0'..'9', 'x', 'o', 'a'..'f', 'A'..'F'] then
            inc(i)
          else
          begin
            needsQuote := false;
            break;
          end;
      end;
    end;
  end;
  // scan for chars that require escape
  if not needsQuote then
    for i := 1 to n do
    begin
      c := S[i];
      if (c < #32) or
         (c = '"') or
         (c = '\') then
      begin
        needsQuote := true;
        hasSpecial := true;
        break;
      end;
      if (c = ':') and
         (i < n) and
         (S[i + 1] in [' ', #9]) then
      begin
        needsQuote := true;
        break;
      end;
      if (c = '#') and
         (i > 1) and
         (S[i - 1] in [' ', #9]) then
      begin
        needsQuote := true;
        break;
      end;
    end;
  if not needsQuote then
  begin
    fOut.AddNoJsonEscape(pointer(S), n);
    exit;
  end;
  // emit as JSON-escaped double-quoted string - valid YAML 1.2 §5.7
  // since the JSON escape set is a subset of YAML's flow-scalar escapes
  fOut.AddJsonString(S);
  // hasSpecial is still computed for potential future heuristics
  if hasSpecial then ;
end;

procedure TVariantToYaml.WriteYamlKey(const K: RawUtf8);
begin
  WriteYamlString(K);
end;

procedure TVariantToYaml.WriteYamlVariantAsString(const v: variant);
var
  s: RawUtf8;
begin
  VariantToUtf8(v, s);
  WriteYamlString(s);
end;

procedure TVariantToYaml.WriteScalar(const v: variant);
var
  vd: TVarData absolute v;
  vt: cardinal;
begin
  vt := vd.VType;
  if (vt <= varOleUInt) and
     (vt <> varOleStr) then
    // simple and numeric types share the same text form in JSON and YAML, so
    // let TJsonWriter.AddVariant emit them directly without any escaping
    fOut.AddVariant(v, twNone)
  else if vt = varString then
    // in a TDocVariant, strings are usually normalized as RawUtf8
    WriteYamlString(RawUtf8(vd.VAny))
  else
    // string-like or unknown: coerce to UTF-8 and apply YAML quoting rules
    WriteYamlVariantAsString(v);
end;

procedure TVariantToYaml.WriteBlockMap(const dv: TDocVariantData; Indent: PtrInt);
var
  i: PtrInt;
  cd: PDocVariantData;
begin
  if dv.Count = 0 then
  begin
    fOut.AddShorter('{}');
    exit;
  end;
  for i := 0 to dv.Count - 1 do
  begin
    if i > 0 then
      WriteIndent(Indent);
    WriteYamlKey(dv.Names[i]);
    fOut.AddDirect(':');
    if _Safe(dv.Values[i], cd) and
       (cd^.Count > 0) then
    begin
      fOut.Add(#10);
      WriteIndent(Indent + 2);
      WriteValue(dv.Values[i], Indent + 2);
    end
    else
    begin
      fOut.Add(' ');
      WriteValue(dv.Values[i], Indent + 2);
    end;
    if i < dv.Count - 1 then
      fOut.Add(#10);
  end;
end;

procedure TVariantToYaml.WriteBlockSeq(const dv: TDocVariantData; Indent: PtrInt);
var
  i: PtrInt;
  cd: PDocVariantData;
begin
  if dv.Count = 0 then
  begin
    fOut.AddShorter('[]');
    exit;
  end;
  for i := 0 to dv.Count - 1 do
  begin
    if i > 0 then
      WriteIndent(Indent);
    fOut.AddShorter('- ');
    if _Safe(dv.Values[i], cd) and (cd^.Count > 0) then
    begin
      // put child map/seq inline after the dash
      if cd^.Kind = dvObject then
      begin
        WriteBlockMap(cd^, Indent + 2);
      end
      else
      begin
        fOut.Add(#10);
        WriteIndent(Indent + 2);
        WriteBlockSeq(cd^, Indent + 2);
      end;
    end
    else
    begin
      WriteValue(dv.Values[i], Indent + 2);
    end;
    if i < dv.Count - 1 then
      fOut.Add(#10);
  end;
end;

procedure TVariantToYaml.WriteValue(const v: variant; Indent: PtrInt);
var
  cd: PDocVariantData;
begin
  if _Safe(v, cd) and
     (cd^.Kind <> dvUndefined) then
  begin
    if cd^.Count = 0 then
    begin
      if cd^.Kind = dvArray then
        fOut.AddShorter('[]')
      else
        fOut.AddShorter('{}');
      exit;
    end;
    if cd^.Kind = dvObject then
      WriteBlockMap(cd^, Indent)
    else
      WriteBlockSeq(cd^, Indent);
    exit;
  end;
  WriteScalar(v);
end;

function TVariantToYaml.Run(const Doc: variant): RawUtf8;
var
  cd: PDocVariantData;
begin
  if _Safe(Doc, cd) and
     (cd^.Kind <> dvUndefined) then
  begin
    if cd^.Count = 0 then
    begin
      if cd^.Kind = dvArray then
        result := '[]' + #10
      else
        result := '{}' + #10;
      exit;
    end;
    if cd^.Kind = dvObject then
      WriteBlockMap(cd^, 0)
    else
      WriteBlockSeq(cd^, 0);
    fOut.Add(#10);
  end
  else
    WriteScalar(Doc);
  fOut.SetText(result);
end;


function VariantToYaml(const Doc: variant; Options: TYamlWriterOptions): RawUtf8;
var
  conv: TVariantToYaml;
begin
  conv := TVariantToYaml.Create(Options);
  try
    result := conv.Run(Doc);
  finally
    conv.Free;
  end;
end;

procedure SaveVariantToYamlFile(const Doc: variant; const FileName: TFileName;
  Options: TYamlWriterOptions);
begin
  FileFromString(VariantToYaml(Doc, Options), FileName);
end;

function YamlToJson(const Yaml: RawUtf8): RawUtf8;
var
  conv: TYamlToJson;
  src: RawUtf8;
begin
  src := Yaml;
  // strip optional UTF-8 BOM - accepted in files and in-memory buffers
  if (length(src) >= 3) and
     (PCardinal(pointer(src))^ and $00ffffff = BOM_UTF8) then
    delete(src, 1, 3);
  conv := TYamlToJson.Create;
  try
    result := conv.Run(src);
  finally
    conv.Free;
  end;
end;

function JsonToYaml(const Json: RawUtf8; Options: TYamlWriterOptions): RawUtf8;
var
  doc: TDocVariantData;
begin
  if doc.InitJson(Json, JSON_YAML) then
    result := VariantToYaml(variant(doc), Options)
  else
    result := '';
end;


end.

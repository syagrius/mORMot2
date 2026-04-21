/// regression tests for mormot.core.yaml unit
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit test.core.yaml;

interface

{$I ..\src\mormot.defines.inc}

uses
  sysutils,
  classes,
  variants,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.data,
  mormot.core.variants,
  mormot.core.test,
  mormot.core.yaml;

type
  /// regression tests for mormot.core.yaml features
  TTestCoreYaml = class(TSynTestCase)
  protected
    procedure RunGolden(const Name, Yaml, ExpectedJson: RawUtf8);
    procedure ExpectRaise(const Name, Yaml: RawUtf8);
  published
    /// parse YAML happy paths and compare TDocVariantData.ToJson
    procedure _ParseGolden;
    /// parse then serialize then parse, compare equivalence
    procedure _Roundtrip;
    /// unsupported constructs must raise EYamlException with line info
    procedure _ErrorCases;
    /// YamlFileToVariant reads via OS file I/O
    procedure _FileApi;
    /// pathological deep nesting must raise EYamlException, not EStackOverflow
    // - covers the Stripe 6 MB spec3 public stress-test failure mode
    procedure _RecursionDepth;
    /// an OpenAPI-shaped spec in YAML must yield the same TDocVariantData
    // as its JSON counterpart - this is the invariant mopenapi relies on
    procedure _OpenApiEquivalence;
  end;


implementation


{ TTestCoreYaml }

type
  TYamlGoldenCase = record
    Name: RawUtf8;
    Yaml: RawUtf8;
    ExpectedJson: RawUtf8;
  end;

const
  // golden cases, covering the I/O matrix of spec-yaml-support.md
  GOLDEN: array[0..31] of TYamlGoldenCase = (
    (Name: 'empty-flow-map';
     Yaml: '{}';
     ExpectedJson: '{}'),
    (Name: 'empty-flow-seq';
     Yaml: '[]';
     ExpectedJson: '[]'),
    (Name: 'block-map-simple';
     Yaml: 'a: 1'#10'b: two';
     ExpectedJson: '{"a":1,"b":"two"}'),
    (Name: 'block-seq-simple';
     Yaml: '- x'#10'- y';
     ExpectedJson: '["x","y"]'),
    (Name: 'nested-seq-of-map';
     Yaml: 'list:'#10'  - a: 1';
     ExpectedJson: '{"list":[{"a":1}]}'),
    (Name: 'compact-seq-same-indent';
     // YAML 1.2 allows "- item" at same indent as parent key (common in OpenAPI)
     Yaml: 'servers:'#10'- url: /api'#10'tags:'#10'- name: pet'#10'  description: dogs';
     ExpectedJson: '{"servers":[{"url":"/api"}],"tags":[{"name":"pet","description":"dogs"}]}'),
    (Name: 'leading-doc-marker';
     // single "---" at file start is a directives-end marker (not multi-doc);
     // commonly emitted by yq/jq/Kubernetes/GitHub specs
     Yaml: '---'#10'a: 1'#10'b: 2';
     ExpectedJson: '{"a":1,"b":2}'),
    (Name: 'dash3-in-block-scalar';
     // indented "---" inside a literal block must be treated as literal
     // content, not as a multi-doc marker (seen in github REST API spec)
     Yaml: 'k: |'#10'  line1'#10'  ---'#10'  line3';
     ExpectedJson: '{"k":"line1\n---\nline3\n"}'),
    (Name: 'nested-map-of-seq';
     Yaml: 'outer:'#10'  inner:'#10'    - 1'#10'    - 2';
     ExpectedJson: '{"outer":{"inner":[1,2]}}'),
    (Name: 'flow-inline-mixed';
     Yaml: '{a: [1, 2], b: {c: d}}';
     ExpectedJson: '{"a":[1,2],"b":{"c":"d"}}'),
    (Name: 'scalar-types';
     Yaml: 'n: null'#10'b: true'#10'i: 42'#10'f: 3.14'#10's: hi';
     ExpectedJson: '{"n":null,"b":true,"i":42,"f":3.14,"s":"hi"}'),
    (Name: 'scalar-null-variants';
     Yaml: 'a: ~'#10'b:'#10'c: Null';
     ExpectedJson: '{"a":null,"b":null,"c":null}'),
    (Name: 'quoted-keeps-string';
     Yaml: 'a: "1"'#10'b: ''true''';
     ExpectedJson: '{"a":"1","b":"true"}'),
    (Name: 'literal-block';
     Yaml: 'k: |'#10'  line1'#10'  line2';
     ExpectedJson: '{"k":"line1\nline2\n"}'),
    (Name: 'folded-block';
     Yaml: 'k: >'#10'  line1'#10'  line2';
     ExpectedJson: '{"k":"line1 line2\n"}'),
    (Name: 'literal-strip-chomp';
     Yaml: 'k: |-'#10'  line1'#10'  line2';
     ExpectedJson: '{"k":"line1\nline2"}'),
    (Name: 'trailing-comment';
     Yaml: 'a: 1 # ignore'#10'b: 2';
     ExpectedJson: '{"a":1,"b":2}'),
    (Name: 'negative-and-float';
     Yaml: 'a: -7'#10'b: -0.5'#10'c: 1e3';
     ExpectedJson: '{"a":-7,"b":-0.5,"c":1000}'),
    (Name: 'multiline-quoted-backslash';
     // YAML 1.2 §7.5 double-quoted line-continuation via trailing backslash;
     // discovered via Swagger petstore3.yaml line 167
     Yaml: 'description: "Use\'#10'    \ tag1, tag2 for testing."';
     ExpectedJson: '{"description":"Use tag1, tag2 for testing."}'),
    (Name: 'multiline-quoted-folding';
     // YAML 1.2 §7.5 quoted multi-line without trailing \: line-break folds to space
     Yaml: 'k: "line one'#10'  line two"';
     ExpectedJson: '{"k":"line one line two"}'),
    (Name: 'block-key-inline-empty-flow-seq';
     // "key: []" on the RHS of a block-map entry is legal YAML (and common in
     // OpenAPI, e.g. "parameters: []"); regressed against a latent infinite-
     // recursion path in ParseBlockMap previously masked by the 3 fixes above
     Yaml: 'parameters: []'#10'responses: {}';
     ExpectedJson: '{"parameters":[],"responses":{}}'),
    (Name: 'block-key-inline-flow-seq-nonempty';
     Yaml: 'tags: [a, b, c]'#10'name: x';
     ExpectedJson: '{"tags":["a","b","c"],"name":"x"}'),
    (Name: 'markdown-bold-not-alias';
     // "**text**" inside a plain scalar must NOT be rejected as a YAML alias;
     // 182 hits in the GitHub REST API spec once plain-scalar folding is on
     Yaml: 'description: foo **Required** bar';
     ExpectedJson: '{"description":"foo **Required** bar"}'),
    (Name: 'plain-scalar-folded';
     // YAML 1.2 §6.5 plain scalar folding: continuation indented > key indent;
     // discovered via GitHub REST api.github.com.yaml line 156
     Yaml: 'description: If specified, only advisories with this'#10 +
           '  GHSA identifier will be returned.';
     ExpectedJson:
       '{"description":"If specified, only advisories with this GHSA ' +
       'identifier will be returned."}'),
    (Name: 'plain-scalar-folded-with-quotes';
     // GitHub REST spec §3541 continuation line starts with "; that is
     // literal text in a folded plain scalar, not a new quoted scalar
     Yaml: 'description: slug example, such as'#10 +
           '  "My TEam" would become team.';
     ExpectedJson:
       '{"description":"slug example, such as \"My TEam\" would become team."}'),
    (Name: 'ampersand-in-url-is-not-anchor';
     // mid-scalar '&' in query strings is literal text, not an anchor;
     // 27 hits in the GitHub REST spec once plain-scalar folding is on
     Yaml: 'example: https://x.test/?a=1&b=2&c=3';
     ExpectedJson: '{"example":"https://x.test/?a=1&b=2&c=3"}'),
    (Name: 'markdown-image-not-tag';
     // "![alt](url)" in plain-scalar text is markdown, not a YAML tag;
     // 215 hits in the GitHub REST spec
     Yaml: 'description: see ![icon](https://x.test/a.png) inline.';
     ExpectedJson:
       '{"description":"see ![icon](https://x.test/a.png) inline."}'),
    (Name: 'plain-scalar-folded-with-brackets';
     // GitHub REST spec §9656 - a folded plain scalar embeds markdown links
     // like "[text](url)", so a continuation line starting with '[' is text
     Yaml: 'description: uses the'#10 +
           '  [List endpoint](https://example.test) for details.';
     ExpectedJson:
       '{"description":"uses the [List endpoint](https://example.test) ' +
       'for details."}'),
    (Name: 'literal-explicit-indent';
     // YAML 1.2 §8.1.1.1 explicit-indent block scalar: "|2" forces
     // content indent = parent+2, overriding auto-detection. First content
     // line is deeper than parent+2, so auto-detect would mis-compute and
     // break out on the shallower second line.
     Yaml: 'k: |2'#10'      line1'#10'    line2';
     ExpectedJson: '{"k":"    line1\n  line2\n"}'),
    (Name: 'folded-explicit-indent';
     // ">2" sibling of "|2" for folded style: same indent rule applies and
     // line-break -> space folding still works. After stripping blockIndent=2,
     // line1 is "    one" (4 spaces) and line2 is "  two" (2 spaces); folding
     // injects a single space between them, yielding 3 spaces mid-output.
     Yaml: 'k: >2'#10'      one'#10'    two';
     ExpectedJson: '{"k":"    one   two\n"}'),
    (Name: 'explicit-indent-varying-depth';
     // real GitHub REST octocat shape: content lines vary from deeper
     // to shallower but all >= parent+2; auto-detect would truncate at
     // the second line because its indent is less than the first line.
     Yaml: 'v: |2'#10'       A'#10'      B'#10'       C';
     ExpectedJson: '{"v":"     A\n    B\n     C\n"}'),
    (Name: 'nested-compact-seq-of-seq';
     // YAML 1.2 compact nested block-seq: "- - X" on one physical line
     // starts a new inner seq at (outer Indent + 2); following lines at
     // that depth continue the inner seq. Discovered via GitHub REST spec
     // line 223996 (sort_by: [[123, asc], [456, desc]]).
     Yaml: 'k:'#10'- - 1'#10'  - 2'#10'- - 3'#10'  - 4';
     ExpectedJson: '{"k":[[1,2],[3,4]]}')
  );

  ERRORS: array[0..8] of TYamlGoldenCase = (
    (Name: 'anchor';
     Yaml: 'a: &ref 1'#10'b: *ref';
     ExpectedJson: ''),
    (Name: 'alias-only';
     Yaml: 'a: *missing';
     ExpectedJson: ''),
    (Name: 'explicit-tag';
     Yaml: 'a: !!str 1';
     ExpectedJson: ''),
    (Name: 'multi-doc-separator';
     Yaml: '---'#10'a: 1'#10'---'#10'b: 2';
     ExpectedJson: ''),
    (Name: 'bad-indent';
     Yaml: 'a:'#10'  b: 1'#10' c: 2';
     ExpectedJson: ''),
    (Name: 'tab-indent';
     Yaml: 'a:'#10#9'b: 1';
     ExpectedJson: ''),
    (Name: 'yaml-directive';
     Yaml: '%YAML 1.2'#10'a: 1';
     ExpectedJson: ''),
    (Name: 'tag-directive';
     Yaml: '%TAG ! tag:example.com,2024:'#10'a: 1';
     ExpectedJson: ''),
    (Name: 'explicit-indent-zero';
     // YAML 1.2 §8.1.1.1 forbids 0 as an explicit indent indicator
     Yaml: 'k: |0'#10'  x';
     ExpectedJson: '')
  );

procedure TTestCoreYaml.RunGolden(const Name, Yaml, ExpectedJson: RawUtf8);
var
  doc: TDocVariantData;
  actual: RawUtf8;
  ok: boolean;
begin
  doc.Clear;
  ok := YamlToVariant(Yaml, doc);
  CheckUtf8(ok, 'YamlToVariant returned false for %', [Name]);
  actual := doc.ToJson;
  CheckEqual(actual, ExpectedJson, FormatUtf8('golden "%"', [Name]));
end;

procedure TTestCoreYaml.ExpectRaise(const Name, Yaml: RawUtf8);
var
  doc: TDocVariantData;
  raised: boolean;
begin
  doc.Clear;
  raised := false;
  try
    YamlToVariant(Yaml, doc);
  except
    on EYamlException do
      raised := true;
  end;
  CheckUtf8(raised, 'expected EYamlException for %', [Name]);
end;

procedure TTestCoreYaml._ParseGolden;
var
  i: PtrInt;
begin
  for i := low(GOLDEN) to high(GOLDEN) do
    RunGolden(GOLDEN[i].Name, GOLDEN[i].Yaml, GOLDEN[i].ExpectedJson);
end;

procedure TTestCoreYaml._Roundtrip;
var
  i: PtrInt;
  doc1, doc2: TDocVariantData;
  yaml: RawUtf8;
begin
  for i := low(GOLDEN) to high(GOLDEN) do
  begin
    doc1.Clear;
    doc2.Clear;
    // first parse MUST succeed for every golden case; silently skipping would
    // let real regressions pass this test - that is the anti-pattern
    CheckUtf8(YamlToVariant(GOLDEN[i].Yaml, doc1),
      'roundtrip initial parse failed for %', [GOLDEN[i].Name]);
    yaml := VariantToYaml(variant(doc1));
    CheckUtf8(YamlToVariant(yaml, doc2),
      'roundtrip parse-2 failed for %', [GOLDEN[i].Name]);
    CheckEqual(doc2.ToJson, doc1.ToJson,
      FormatUtf8('roundtrip "%"', [GOLDEN[i].Name]));
  end;
end;

procedure TTestCoreYaml._ErrorCases;
var
  i: PtrInt;
begin
  for i := low(ERRORS) to high(ERRORS) do
    ExpectRaise(ERRORS[i].Name, ERRORS[i].Yaml);
end;

procedure TTestCoreYaml._FileApi;
var
  fn: TFileName;
  doc: TDocVariantData;
  raised: boolean;
  yamlBom: RawUtf8;
begin
  fn := WorkDir + 'test.core.yaml.tmp.yaml';
  FileFromString('a: 1'#10'b: 2'#10, fn);
  try
    doc.Clear;
    Check(YamlFileToVariant(fn, doc), 'YamlFileToVariant returned false');
    CheckEqual(doc.ToJson, '{"a":1,"b":2}', 'file api');
  finally
    DeleteFile(fn);
  end;
  // file-not-found must raise EYamlException (patch P10)
  raised := false;
  try
    YamlFileToVariant(WorkDir + 'does.not.exist.yaml', doc);
  except
    on EYamlException do
      raised := true;
  end;
  Check(raised, 'file-not-found must raise EYamlException');
  // BOM must be stripped even in inline YamlToVariant (patch P8)
  yamlBom := #$EF#$BB#$BF + 'a: 1';
  doc.Clear;
  Check(YamlToVariant(yamlBom, doc), 'YamlToVariant with BOM');
  CheckEqual(doc.ToJson, '{"a":1}', 'inline BOM stripped');
end;

procedure TTestCoreYaml._RecursionDepth;
var
  i: PtrInt;
  yaml, indent: RawUtf8;
  saved: integer;
  raised: boolean;
  doc: TDocVariantData;
begin
  saved := YamlMaxDepth;
  try
    // build a nested block-map of depth 20: "a:\n  a:\n    a: ... a: 1"
    yaml := '';
    indent := '';
    for i := 0 to 19 do
    begin
      if i < 19 then
        yaml := yaml + indent + 'a:'#10
      else
        yaml := yaml + indent + 'a: 1'#10;
      indent := indent + '  ';
    end;
    // deep input beyond the cap must raise EYamlException (not EStackOverflow)
    YamlMaxDepth := 8;
    doc.Clear;
    raised := false;
    try
      YamlToVariant(yaml, doc);
    except
      on EYamlException do
        raised := true;
    end;
    Check(raised, 'depth 20 must raise EYamlException when YamlMaxDepth=8');
    // same input parses cleanly when the cap is high enough
    YamlMaxDepth := 100;
    doc.Clear;
    Check(YamlToVariant(yaml, doc),
      'depth 20 must parse when YamlMaxDepth=100');
  finally
    YamlMaxDepth := saved;
  end;
end;

procedure TTestCoreYaml._OpenApiEquivalence;
const
  // a compact OpenAPI 3.0 slice exercising: nested maps, arrays, $ref,
  // numeric-looking keys (the "200" response code) and boolean properties
  OPENAPI_YAML: RawUtf8 =
    'openapi: 3.0.0'#10 +
    'info:'#10 +
    '  title: Petstore'#10 +
    '  version: 1.0.0'#10 +
    'paths:'#10 +
    '  /pets:'#10 +
    '    get:'#10 +
    '      operationId: listPets'#10 +
    '      parameters:'#10 +
    '        - name: limit'#10 +
    '          in: query'#10 +
    '          required: false'#10 +
    '          schema:'#10 +
    '            type: integer'#10 +
    '      responses:'#10 +
    '        "200":'#10 +
    '          description: OK'#10 +
    '          content:'#10 +
    '            application/json:'#10 +
    '              schema:'#10 +
    '                $ref: "#/components/schemas/Pet"'#10 +
    'components:'#10 +
    '  schemas:'#10 +
    '    Pet:'#10 +
    '      type: object'#10 +
    '      required:'#10 +
    '        - id'#10 +
    '        - name'#10 +
    '      properties:'#10 +
    '        id:'#10 +
    '          type: integer'#10 +
    '        name:'#10 +
    '          type: string'#10;
  OPENAPI_JSON: RawUtf8 =
    '{"openapi":"3.0.0",' +
    '"info":{"title":"Petstore","version":"1.0.0"},' +
    '"paths":{"/pets":{"get":{"operationId":"listPets",' +
    '"parameters":[{"name":"limit","in":"query","required":false,' +
    '"schema":{"type":"integer"}}],' +
    '"responses":{"200":{"description":"OK",' +
    '"content":{"application/json":{"schema":{' +
    '"$ref":"#/components/schemas/Pet"}}}}}}}},' +
    '"components":{"schemas":{"Pet":{"type":"object",' +
    '"required":["id","name"],' +
    '"properties":{"id":{"type":"integer"},"name":{"type":"string"}}}}}}';
const
  // must match YamlToVariant's default so the two sides are compared apples-
  // to-apples; otherwise dvoAllowDoubleValue and friends could produce
  // divergent ToJson output
  OPENAPI_OPT: TDocVariantOptions =
    [dvoReturnNullForUnknownProperty, dvoValueCopiedByReference,
     dvoInternNames, dvoAllowDoubleValue];
var
  fromYaml, fromJson: TDocVariantData;
begin
  fromYaml.Clear;
  fromJson.Clear;
  Check(YamlToVariant(OPENAPI_YAML, fromYaml, OPENAPI_OPT), 'YamlToVariant');
  Check(fromJson.InitJson(OPENAPI_JSON, OPENAPI_OPT), 'InitJson');
  CheckEqual(fromYaml.ToJson, fromJson.ToJson,
    'OpenAPI-shaped YAML must match JSON equivalent');
end;


end.

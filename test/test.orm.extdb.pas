/// regression tests for ORM process over external SQL DB engines
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit test.orm.extdb;

interface

{$I ..\src\mormot.defines.inc}

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.buffers,
  mormot.core.unicode,
  mormot.core.datetime,
  mormot.core.rtti,
  mormot.crypt.core,
  mormot.core.data,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.core.mustache,
  mormot.core.test,
  mormot.db.core,
  mormot.db.sql,
  mormot.db.sql.sqlite3,
  mormot.db.sql.oledb,
  mormot.db.nosql.bson,
  mormot.db.raw.sqlite3,
  mormot.db.raw.sqlite3.static,
  mormot.db.proxy,
  mormot.orm.base,
  mormot.orm.core,
  mormot.orm.storage,
  mormot.orm.sql,
  mormot.orm.rest,
  mormot.orm.client,
  mormot.orm.server,
  mormot.soa.core,
  mormot.rest.core,
  mormot.rest.client,
  mormot.rest.server,
  mormot.rest.memserver,
  mormot.rest.sqlite3,
  mormot.rest.http.server,
  mormot.rest.http.client,
  test.core.base,
  test.core.data,
  test.orm.sqlite3;

type
  /// a test case which will test most external DB functions of the
  // mormot.orm.sql.pas unit
  // - the external DB will be in fact a SQLite3 instance, expecting a
  // test.db3 file available in the current directory, populated with
  // some TOrmPeople rows
  // - note that SQL statement caching at SQLite3 engine level makes those test
  // 2 times faster: nice proof of performance improvement
  TTestExternalDatabase = class(TSynTestCase)
  protected
    fExternalModel: TOrmModel;
    fPeopleData: TOrmTable;
    /// called by ExternalViaREST/ExternalViaVirtualTable and
    // ExternalViaRESTWithChangeTracking tests method
    procedure Test(StaticVirtualTableDirect, TrackChanges: boolean);
  public
    /// release used instances (e.g. server) and memory
    procedure CleanUp; override;
  published
    /// test SynDB connection remote access via HTTP
    procedure _SynDBRemote;
    /// test TSqlDBConnectionProperties persistent as JSON
    procedure DBPropertiesPersistence;
    /// initialize needed RESTful client (and server) instances
    // - i.e. a RESTful direct access to an external DB
    procedure ExternalRecords;
    /// check the SQL auto-adaptation features
    procedure AutoAdaptSQL;
    /// check the per-db encryption
    // - the testpass.db3-wal file is not encrypted, but the main
    // testpass.db3 file will
    procedure CryptedDatabase;
    /// test external DB implementation via faster REST calls
    // - will mostly call directly the TRestStorageExternal instance,
    // bypassing the Virtual Table mechanism of SQLite3
    procedure ExternalViaREST;
    /// test external DB implementation via slower Virtual Table calls
    // - using the Virtual Table mechanism of SQLite3 is more than 2 times
    // slower than direct REST access
    procedure ExternalViaVirtualTable;
    /// test external DB implementation via faster REST calls and change tracking
    // - a TOrmHistory table will be used to store record history
    procedure ExternalViaRESTWithChangeTracking;
    {$ifdef CPU32}
    {$ifdef OSWINDOWS}
    /// test external DB using the JET engine
    procedure JETDatabase;
    {$endif OSWINDOWS}
    {$endif CPU32}
    {$ifdef OSWINDOWS}
    {$ifdef USEZEOS}
    /// test external Firebird embedded engine via Zeos/ZDBC (if available)
    procedure FirebirdEmbeddedViaZDBCOverHTTP;
    {$endif USEZEOS}
    {$endif OSWINDOWS}
  end;

type
  TOrmPeopleExt = class(TOrm)
  private
    fFirstName: RawUtf8;
    fLastName: RawUtf8;
    fData: RawBlob;
    fYearOfBirth: integer;
    fYearOfDeath: word;
    fValue: TVariantDynArray;
    fLastChange: TModTime;
    fCreatedAt: TCreateTime;
  published
    property FirstName: RawUtf8
      index 40 read fFirstName write fFirstName;
    property LastName: RawUtf8
      index 40 read fLastName write fLastName;
    property Data: RawBlob
      read fData write fData;
    property YearOfBirth: integer
      read fYearOfBirth write fYearOfBirth;
    property YearOfDeath: word
      read fYearOfDeath write fYearOfDeath;
    property Value: TVariantDynArray
      read fValue write fValue;
    property LastChange: TModTime
      read fLastChange;
    property CreatedAt: TCreateTime
      read fCreatedAt write fCreatedAt;
  end;

  TOrmOnlyBlob = class(TOrm)
  private
    fData: RawBlob;
  published
    property Data: RawBlob
      read fData write fData;
  end;

  TOrmTestJoin = class(TOrm)
  private
    fName: RawUtf8;
    fPeople: TOrmPeopleExt;
  published
    property Name: RawUtf8
      index 30 read fName write fName;
    property People: TOrmPeopleExt
      read fPeople write fPeople;
  end;

  TOrmMyHistory = class(TOrmHistory);


implementation


{$ifdef OSWINDOWS}
{$ifdef USEZEOS}

uses
  mormot.db.sql.zeos;

{$endif USEZEOS}
{$endif OSWINDOWS}

type
  // class hooks to access DMBS property for TTestExternalDatabase.AutoAdaptSQL
  TSqlDBConnectionPropertiesHook = class(TSqlDBConnectionProperties);
  TRestStorageExternalHook = class(TRestStorageExternal);


{ TTestExternalDatabase }

procedure TTestExternalDatabase.ExternalRecords;
var
  sql: RawUtf8;
begin
  if CheckFailed(fExternalModel = nil) then
    exit; // should be called once
  fExternalModel := TOrmModel.Create([TOrmPeopleExt, TOrmOnlyBlob, TOrmTestJoin,
    TOrmASource, TOrmADest, TOrmADests, TOrmPeople, TOrmMyHistory]);
  ReplaceParamsByNames(RawUtf8OfChar('?', 200), sql);
  CheckHash(sql, $AD27D1E0, 'excludes :IF :OF');
end;

procedure TTestExternalDatabase.AutoAdaptSQL;
var
  SqlOrigin, s: RawUtf8;
  Props: TSqlDBConnectionProperties;
  Server: TRestServer;
  Ext: TRestStorageExternalHook;
  v: TRawUtf8DynArray;

  procedure Test(aDbms: TSqlDBDefinition; AdaptShouldWork: boolean;
    const SQLExpected: RawUtf8 = '');
  var
    SQL: RawUtf8;
  begin
    SQL := SqlOrigin;
    TSqlDBConnectionPropertiesHook(Props).fDbms := aDbms;
    Check((Props.Dbms = aDbms) or (aDbms = dUnknown));
    Check(Ext.AdaptSQLForEngineList(SQL) = AdaptShouldWork);
    CheckUtf8(SameTextU(SQL, SQLExpected) or
          not AdaptShouldWork, SQLExpected + #13#10 + SQL);
  end;

  procedure Test2(const Orig, Expected: RawUtf8);
  var
    db: TSqlDBDefinition;
  begin
    SqlOrigin := Orig;
    for db := low(db) to high(db) do
      Test(db, true, Expected);
  end;

begin
  CheckEqual(ReplaceParamsByNumbers('', s), 0);
  CheckEqual(s, '');
  CheckEqual(ReplaceParamsByNumbers('toto titi', s), 0);
  CheckEqual(s, 'toto titi');
  CheckEqual(ReplaceParamsByNumbers('toto=? titi', s), 1);
  CheckEqual(s, 'toto=$1 titi');
  CheckEqual(ReplaceParamsByNumbers('toto=? titi=?', s), 2);
  CheckEqual(s, 'toto=$1 titi=$2');
  CheckEqual(ReplaceParamsByNumbers('toto=? titi=? and a=''''', s), 2);
  CheckEqual(s, 'toto=$1 titi=$2 and a=''''');
  CheckEqual(ReplaceParamsByNumbers('toto=? titi=? and a=''dd''', s), 2);
  CheckEqual(s, 'toto=$1 titi=$2 and a=''dd''');
  CheckEqual(ReplaceParamsByNumbers('toto=? titi=? and a=''d''''d''', s), 2);
  CheckEqual(s, 'toto=$1 titi=$2 and a=''d''''d''');
  CheckEqual(ReplaceParamsByNumbers('toto=? titi=? and a=''d?d''', s), 2);
  CheckEqual(s, 'toto=$1 titi=$2 and a=''d?d''');
  CheckEqual(ReplaceParamsByNumbers('1?2?3?4?5?6?7?8?9?10?11?12? x', s), 12);
  CheckEqual(s, '1$12$23$34$45$56$67$78$89$910$1011$1112$12 x');
  checkequal(BoundArrayToJsonArray(TRawUtf8DynArrayFrom([])), '');
  checkequal(BoundArrayToJsonArray(TRawUtf8DynArrayFrom(['1'])), '{1}');
  checkequal(BoundArrayToJsonArray(TRawUtf8DynArrayFrom(['''1'''])), '{"1"}');
  checkequal(BoundArrayToJsonArray(TRawUtf8DynArrayFrom(['1', '2', '3'])), '{1,2,3}');
  checkequal(BoundArrayToJsonArray(TRawUtf8DynArrayFrom(['''1''', '2', '''3'''])),
    '{"1",2,"3"}');
  checkequal(BoundArrayToJsonArray(TRawUtf8DynArrayFrom(
    ['''1"1''', '2', '''"3\'''])), '{"1\"1",2,"\"3\\"}');
  Check(not JsonArrayToBoundArray(nil, ftUtf8, ' ', false, v));
  s := '{one}';
  Check(not JsonArrayToBoundArray(UniqueRawUtf8(s), ftUtf8, ' ', false, v));
  s := '[]';
  Check(not JsonArrayToBoundArray(UniqueRawUtf8(s), ftUtf8, ' ', false, v));
  s := '[1]';
  Check(JsonArrayToBoundArray(UniqueRawUtf8(s), ftUtf8, ' ', false, v));
  CheckEqual(RawUtf8ArrayToCsv(v), '''1''');
  s := '[1]';
  Check(JsonArrayToBoundArray(UniqueRawUtf8(s), ftInt64, ' ', false, v));
  CheckEqual(RawUtf8ArrayToCsv(v), '1');
  s := '[1,2,3,null]';
  Check(JsonArrayToBoundArray(UniqueRawUtf8(s), ftInt64, ' ', false, v));
  CheckEqual(RawUtf8ArrayToCsv(v), '1,2,3,null');
  s := '["a","''","c"]';
  Check(JsonArrayToBoundArray(UniqueRawUtf8(s), ftUtf8, ' ', false, v));
  CheckEqual(RawUtf8ArrayToCsv(v), '''a'','''''''',''c''');

  Check(TSqlDBConnectionProperties.IsSQLKeyword(dUnknown, 'SELEct'));
  Check(not TSqlDBConnectionProperties.IsSQLKeyword(dUnknown, 'toto'));
  Check(TSqlDBConnectionProperties.IsSQLKeyword(dOracle, 'SELEct'));
  Check(not TSqlDBConnectionProperties.IsSQLKeyword(dOracle, 'toto'));
  Check(TSqlDBConnectionProperties.IsSQLKeyword(dOracle, ' auDIT '));
  Check(not TSqlDBConnectionProperties.IsSQLKeyword(dMySQL, ' auDIT '));
  Check(TSqlDBConnectionProperties.IsSQLKeyword(dSQLite, 'SELEct'));
  Check(TSqlDBConnectionProperties.IsSQLKeyword(dSQLite, 'clustER'));
  Check(not TSqlDBConnectionProperties.IsSQLKeyword(dSQLite, 'value'));

  Server := TRestServerFullMemory.Create(fExternalModel);
  try
    Props := TSqlDBSQLite3ConnectionProperties.Create(
      SQLITE_MEMORY_DATABASE_NAME, '', '', '');
    try
      OrmMapExternal(fExternalModel, TOrmPeopleExt, Props,
        'SampleRecord').MapField('LastChange', 'Changed');
      Ext := TRestStorageExternalHook.Create(
        TOrmPeopleExt, Server.OrmInstance as TRestOrmServer);
      try
        Test2('select rowid,firstname from PeopleExt where rowid=2',
          'select id,firstname from SampleRecord where id=2');
        Test2('select rowid,firstname from PeopleExt where rowid=?',
          'select id,firstname from SampleRecord where id=?');
        Test2('select rowid,firstname from PeopleExt where rowid>=?',
          'select id,firstname from SampleRecord where id>=?');
        Test2('select rowid,firstname from PeopleExt where rowid<?',
          'select id,firstname from SampleRecord where id<?');
        Test2('select rowid,firstname from PeopleExt where rowid=2 and lastname=:(''toto''):',
          'select id,firstname from SampleRecord where id=2 and lastname=:(''toto''):');
        Test2('select rowid,firstname from PeopleExt where rowid=2 and rowID=:(2): order by rowid',
          'select id,firstname from SampleRecord where id=2 and id=:(2): order by id');
        Test2('select rowid,firstname from PeopleExt where rowid=2 or lastname=:(''toto''):',
          'select id,firstname from SampleRecord where id=2 or lastname=:(''toto''):');
        Test2('select rowid,firstname from PeopleExt where rowid=2 and not lastname like ?',
          'select id,firstname from SampleRecord where id=2 and not lastname like ?');
        Test2('select rowid,firstname from PeopleExt where rowid=2 and not (lastname like ?)',
          'select id,firstname from SampleRecord where id=2 and not (lastname like ?)');
        Test2('select rowid,firstname from PeopleExt where (rowid=2 and lastname="toto") or lastname like ?',
          'select id,firstname from SampleRecord where (id=2 and lastname="toto") or lastname like ?');
        Test2('select rowid,firstname from PeopleExt where (rowid=2 or lastname=:("toto"):) and lastname like ?',
          'select id,firstname from SampleRecord where (id=2 or lastname=:("toto"):) and lastname like ?');
        Test2('select rowid,firstname from PeopleExt where (rowid=2) and (lastname="toto" or lastname like ?)',
          'select id,firstname from SampleRecord where (id=2) and (lastname="toto" or lastname like ?)');
        Test2('select rowid,firstname from PeopleExt where (rowid=2) and (lastname=:("toto"): or (lastname like ?))',
          'select id,firstname from SampleRecord where (id=2) and (lastname=:("toto"): or (lastname like ?))');
        Test2('select rowid,firstname from PeopleExt where rowid=2 order by RowID',
          'select id,firstname from SampleRecord where id=2 order by ID');
        Test2('select rowid,firstname from PeopleExt where rowid=2 order by RowID DeSC',
          'select id,firstname from SampleRecord where id=2 order by ID desc');
        Test2('select rowid,firstname from PeopleExt order by RowID,firstName DeSC',
          'select id,firstname from SampleRecord order by ID,firstname desc');
        Test2('select rowid, firstName from PeopleExt order by RowID, firstName',
          'select id,firstname from SampleRecord order by ID,firstname');
        Test2('select rowid, firstName from PeopleExt  order by RowID, firstName asC',
          'select id,firstname from SampleRecord order by ID,firstname');
        Test2('select rowid,firstname from PeopleExt where firstname like :(''test''): order by lastname',
          'select id,firstname from SampleRecord where firstname like :(''test''): order by lastname');
        Test2('   select    COUNT(*)  from   PeopleExt   ',
          'select count(*) from SampleRecord');
        Test2('select count(*) from PeopleExt where rowid=2',
          'select count(*) from SampleRecord where id=2');
        Test2('select count(*) from PeopleExt where rowid=2 /*tobeignored*/',
          'select count(*) from SampleRecord where id=2');
        Test2('select count(*) from PeopleExt where /*tobeignored*/ rowid=2',
          'select count(*) from SampleRecord where id=2');
        Test2('select Distinct(firstname) , max(lastchange)+100 from PeopleExt where rowid >= :(2):',
          'select Distinct(FirstName),max(Changed)+100 as LastChange from SampleRecord where ID>=:(2):');
        Test2('select Distinct(lastchange) , max(rowid)-100 as newid from PeopleExt where rowid >= :(2):',
          'select Distinct(Changed) as lastchange,max(id)-100 as newid from SampleRecord where ID>=:(2):');
        SqlOrigin := 'select rowid,firstname from PeopleExt where   rowid=2   limit 2';
        Test(dUnknown, false);
        Test(dDefault, false);
        Test(dOracle, true,
          'select id,firstname from SampleRecord where rownum<=2 and id=2');
        Test(dMSSQL, true, 'select top(2) id,firstname from SampleRecord where id=2');
        Test(dJet, true, 'select top 2 id,firstname from SampleRecord where id=2');
        Test(dMySQL, true, 'select id,firstname from SampleRecord where id=2 limit 2');
        Test(dSQLite, true, 'select id,firstname from SampleRecord where id=2 limit 2');
        SqlOrigin :=
          'select rowid,firstname from PeopleExt where rowid=2 order by LastName limit 2';
        Test(dUnknown, false);
        Test(dDefault, false);
        Test(dOracle, true,
          'select id,firstname from SampleRecord where rownum<=2 and id=2 order by LastName');
        Test(dMSSQL, true,
          'select top(2) id,firstname from SampleRecord where id=2 order by LastName');
        Test(dJet, true,
          'select top 2 id,firstname from SampleRecord where id=2 order by LastName');
        Test(dMySQL, true,
          'select id,firstname from SampleRecord where id=2 order by LastName limit 2');
        Test(dSQLite, true,
          'select id,firstname from SampleRecord where id=2 order by LastName limit 2');
        SqlOrigin :=
          'select rowid,firstname from PeopleExt where firstname=:(''test''): limit 2';
        Test(dUnknown, false);
        Test(dDefault, false);
        Test(dOracle, true,
          'select id,firstname from SampleRecord where rownum<=2 and firstname=:(''test''):');
        Test(dMSSQL, true,
          'select top(2) id,firstname from SampleRecord where firstname=:(''test''):');
        Test(dJet, true,
          'select top 2 id,firstname from SampleRecord where firstname=:(''test''):');
        Test(dMySQL, true,
          'select id,firstname from SampleRecord where firstname=:(''test''): limit 2');
        Test(dSQLite, true,
          'select id,firstname from SampleRecord where firstname=:(''test''): limit 2');
        SqlOrigin := 'select id,firstname from PeopleExt limit 2';
        Test(dUnknown, false);
        Test(dDefault, false);
        Test(dOracle, true, 'select id,firstname from SampleRecord where rownum<=2');
        Test(dMSSQL, true, 'select top(2) id,firstname from SampleRecord');
        Test(dJet, true, 'select top 2 id,firstname from SampleRecord');
        Test(dMySQL, true, 'select id,firstname from SampleRecord limit 2');
        Test(dSQLite, true, 'select id,firstname from SampleRecord limit 2');
        SqlOrigin := 'select id,firstname from PeopleExt order by firstname limit 2';
        Test(dUnknown, false);
        Test(dDefault, false);
        Test(dOracle, true,
          'select id,firstname from SampleRecord where rownum<=2 order by firstname');
        Test(dMSSQL, true,
          'select top(2) id,firstname from SampleRecord order by firstname');
        Test(dJet, true,
          'select top 2 id,firstname from SampleRecord order by firstname');
        Test(dMySQL, true,
          'select id,firstname from SampleRecord order by firstname limit 2');
        Test(dSQLite, true,
          'select id,firstname from SampleRecord order by firstname limit 2');
        SqlOrigin := 'SELECT RowID,firstname FROM PeopleExt WHERE :(3001): ' +
          'BETWEEN firstname AND RowID LIMIT 1';
        Test(dSQLite, false);
      finally
        Ext.Free;
      end;
    finally
      Props.Free;
    end;
  finally
    Server.Free;
  end;
end;

procedure TTestExternalDatabase.CleanUp;
begin
  FreeAndNil(fExternalModel);
  FreeAndNil(fPeopleData);
  inherited;
end;

procedure TTestExternalDatabase.ExternalViaREST;
begin
  Test(true, false);
end;

procedure TTestExternalDatabase.ExternalViaVirtualTable;
begin
  Test(false, false);
end;

procedure TTestExternalDatabase.ExternalViaRESTWithChangeTracking;
begin
  Test(true, true);
end;

{$ifdef OSWINDOWS}
{$ifdef USEZEOS}

const
  // if this library file is available and USEZEOS conditional is set, will run
  //   TTestExternalDatabase.FirebirdEmbeddedViaODBC
  // !! download driver from http://www.firebirdsql.org/en/odbc-driver
  FIREBIRDEMBEDDEDDLL =
    'd:\Dev\Lib\SQLite3\Samples\15 - External DB performance\Firebird' +
    {$ifdef CPU64} '64' + {$endif=} '\fbembed.dll';

procedure TTestExternalDatabase.FirebirdEmbeddedViaZDBCOverHTTP;
var
  R: TOrmPeople;
  Model: TOrmModel;
  Props: TSqlDBConnectionProperties;
  Server: TRestServerDB;
  Http: TRestHttpServer;
  Client: TRestClientURI;
  i, n: integer;
  ids: array[0..3] of TID;
  res: TIDDynArray;
begin
  if not FileExists(FIREBIRDEMBEDDEDDLL) then
    exit;
  Model := TOrmModel.Create([TOrmPeople]);
  try
    R := TOrmPeople.Create;
    try
      DeleteFile('test.fdb'); // will be re-created at first connection
      Props := TSqlDBZeosConnectionProperties.Create(
        TSqlDBZeosConnectionProperties.URI(
          dFirebird, '', FIREBIRDEMBEDDEDDLL, False), 'test.fdb', '', '');
      try
        OrmMapExternal(Model, TOrmPeople, Props, 'peopleext').
          MapFields(['ID', 'key',
                     'YearOfBirth', 'yob']);
        Server := TRestServerDB.Create(Model, SQLITE_MEMORY_DATABASE_NAME);
        try
          Server.CreateMissingTables;
          Http := TRestHttpServer.Create(HTTP_DEFAULTPORT, Server);
          Client := TRestHttpClient.Create('localhost', HTTP_DEFAULTPORT,
            TOrmModel.Create(Model));
          Client.Model.Owner := Client;
          try
            R.FillPrepare(fPeopleData);
            if not CheckFailed(R.FillContext <> nil) then
            begin
              Client.BatchStart(TOrmPeople);
              n := 0;
              while R.FillOne do
              begin
                R.YearOfBirth := n;
                Client.BatchAdd(R, true);
                inc(n);
              end;
              Check(Client.BatchSend(res) = HTTP_SUCCESS);
              Check(length(res) = n);
              for i := 1 to 100 do
              begin
                R.ClearProperties;
                Check(Client.Retrieve(res[Random(n)], R));
                Check(R.ID <> 0);
                Check(res[R.YearOfBirth] = R.ID);
              end;
            end;
            for i := 0 to high(ids) do
            begin
              R.YearOfBirth := i;
              ids[i] := Client.Add(R, true);
            end;
            for i := 0 to high(ids) do
            begin
              Check(Client.Retrieve(ids[i], R));
              Check(R.YearOfBirth = i);
            end;
            for i := 0 to high(ids) do
            begin
              Client.BatchStart(TOrmPeople, {autotrans=}0);
              Client.BatchDelete(ids[i]);
              Check(Client.BatchSend(res) = HTTP_SUCCESS);
              Check(length(res) = 1);
              Check(res[0] = HTTP_SUCCESS);
            end;
            for i := 0 to high(ids) do
              Check(not Client.Retrieve(ids[i], R));
            R.ClearProperties;
            for i := 0 to high(ids) do
            begin
              R.IDValue := ids[i];
              Check(Client.Update(R), 'test locking');
            end;
            for i := 0 to high(ids) do
            begin
              R.YearOfBirth := i;
              ids[i] := Client.Add(R, true);
            end;
            for i := 0 to high(ids) do
            begin
              Check(Client.Retrieve(ids[i], R));
              Check(R.YearOfBirth = i);
            end;
          finally
            Client.Free;
            Http.Free;
          end;
        finally
          Server.Free;
        end;
      finally
        Props.Free;
      end;
    finally
      R.Free;
    end;
  finally
    Model.Free;
  end;
end;

{$endif USEZEOS}
{$endif OSWINDOWS}

{$ifdef CPU32}
{$ifdef OSWINDOWS}

procedure TTestExternalDatabase.JETDatabase;
var
  R: TOrmPeople;
  Model: TOrmModel;
  Props: TSqlDBConnectionProperties;
  Client: TRestClientDB;
  i, n, ID, LastID: integer;
begin
  Model := TOrmModel.Create([TOrmPeople]);
  try
    R := TOrmPeople.Create;
    R.FillPrepare(fPeopleData);
    if not CheckFailed(R.FillContext <> nil) then
    try
      DeleteFile('test.mdb');
      Props := TSqlDBOleDBJetConnectionProperties.Create('test.mdb', '', '', '');
      try
        OrmMapExternal(Model, TOrmPeople, Props, '');
        Client := TRestClientDB.Create(
          Model, nil, SQLITE_MEMORY_DATABASE_NAME, TRestServerDB);
        try
          Client.Server.Server.CreateMissingTables;
          Client.Orm.TransactionBegin(TOrmPeople);
          n := 0;
          while R.FillOne do
          begin
            inc(n);
            Check(Client.Orm.Add(R, true, true) =
              R.FillContext.Table.GetID(n));
            if n > 999 then
              break; // Jet is very slow e.g. within the Delphi IDE
          end;
          Client.Orm.Commit;
          R.FirstName := '';
          R.LastName := '';
          R.YearOfBirth := 100;
          R.YearOfDeath := 0;
          R.Data := '';
          LastID := Client.Orm.Add(R, true);
          for i := 1 to n do
          begin
            R.ClearProperties;
            ID := R.FillContext.Table.GetID(n);
            Check(Client.Orm.Retrieve(ID, R));
            Check(R.IDValue = ID);
            Check(R.ID = ID);
            Check(R.FirstName <> '');
            Check(R.YearOfBirth >= 1400);
            Check(R.YearOfDeath >= 1468);
          end;
          Check(Client.Orm.Retrieve(LastID, R));
          Check(R.FirstName = '');
          Check(R.LastName = '');
          Check(R.YearOfBirth = 100);
          Check(R.YearOfDeath = 0);
          Check(R.Data = '');
        finally
          Client.Free;
        end;
      finally
        Props.Free;
      end;
    finally
      R.Free;
    end;
  finally
    Model.Free;
  end;
end;

{$endif OSWINDOWS}
{$endif CPU32}

procedure TTestExternalDatabase._SynDBRemote;
var
  Props: TSqlDBConnectionProperties;

  procedure DoTest(proxy: TSqlDBConnectionProperties; msg: PUtf8Char);

    procedure DoTests;
    var
      res: ISqlDBRows;
      id, lastid, i, n, n1: integer;
      IDs: TIntegerDynArray;
      Row, RowDoc, all: variant;
      r, v: PDocVariantData;

      procedure DoInsert;
      var
        i: integer;
      begin
        for i := 0 to high(IDs) do
          Check(proxy.ExecuteNoResult(
            'INSERT INTO People (ID,FirstName,LastName,YearOfBirth,YearOfDeath) ' +
            'VALUES (?,?,?,?,?)', [IDs[i], 'FirstName New ' + Int32ToUtf8(i),
            'New Last', i + 1400, 1519]) = 1);
      end;

      function DoCount: integer;
      var
        res: ISqlDBRows;
      begin
        res := proxy.Execute(
          'select count(*) from People where YearOfDeath=?', [1519]);
        {%H-}Check(res.Step);
        result := res.ColumnInt(0);
        res.ReleaseRows;
      end;

    var
      log: ISynLog;
    begin
      log := TSynLogTestLog.Enter(proxy, msg);
      if proxy <> Props then
        Check(proxy.UserID = 'user');
      proxy.ExecuteNoResult('delete from people where ID>=?', [50000]);
      res := proxy.Execute('select * from People where YearOfDeath=?', [1519]);
      Check(res <> nil);
      n := 0;
      lastid := 0;
      while res.Step do
      begin
        id := res.ColumnInt('ID');
        Check(id <> lastid);
        Check(id > 0);
        lastid := id;
        Check(res.ColumnInt('YearOfDeath') = 1519);
        inc(n);
      end;
      Check(n = DoCount);
      n1 := n;
      n := 0;
      Row := res.RowData;
      if res.Step({rewind=}true) then
        repeat
          Check(Row.ID > 0);
          CheckEqual(Row.YearOfDeath, 1519);
          res.RowDocVariant(RowDoc);
          CheckEqual(RowDoc.ID, Row.ID);
          CheckEqual(_Safe(RowDoc)^.I['YearOfDeath'], 1519);
          inc(n);
        until not res.Step;
      Check(res <> nil);
      Check(n = n1);
      Check(res.Step({first=}true), 'rewind');
      all := res.FetchAllToDocVariantArray; // makes ReleaseRows
      r := _Safe(all);
      CheckEqual(r^.Count, n);
      for i := 0 to r^.Count - 1 do
      begin
        v := _Safe(r^.Values[i]);
        Check(v^.I['id'] > 0);
        CheckEqual(v^.I['YearOfDeath'], 1519);
      end;
      SetLength(IDs, 50);
      FillIncreasing(pointer(IDs), 50000, length(IDs));
      proxy.ThreadSafeConnection.StartTransaction;
      DoInsert;
      proxy.ThreadSafeConnection.Rollback;
      Check(DoCount = n);
      proxy.ThreadSafeConnection.StartTransaction;
      DoInsert;
      proxy.ThreadSafeConnection.Commit;
      n1 := DoCount;
      Check(n1 = n + length(IDs));
      proxy.ExecuteNoResult('delete from people where ID>=?', [50000]);
      Check(DoCount = n);
    end;

  begin
    try
      DoTests;
    finally
      if proxy <> Props then
        proxy.Free;
    end;
  end;

var
  Server: TSqlDBServerAbstract;
const
  ADDR = '127.0.0.1:' + HTTP_DEFAULTPORT;
begin
  Props := TSqlDBSQLite3ConnectionProperties.Create('test.db3', '', '', '');
  try
    DoTest(Props, 'raw Props');
    DoTest(TSqlDBRemoteConnectionPropertiesTest.Create(
      Props, 'user', 'pass', TSqlDBProxyConnectionProtocol), 'proxy test');
    DoTest(TSqlDBRemoteConnectionPropertiesTest.Create(
      Props, 'user', 'pass', TSqlDBRemoteConnectionProtocol), 'remote test');
    Server := TSqlDBServerRemote.Create(
      Props, 'root', HTTP_DEFAULTPORT, 'user', 'pass');
    try
      DoTest(TSqlDBSocketConnectionProperties.Create(
        ADDR, 'root', 'user', 'pass'), 'socket');
      {$ifdef USEWININET}
      DoTest(TSqlDBWinHTTPConnectionProperties.Create(
        ADDR, 'root', 'user', 'pass'), 'winhttp');
      DoTest(TSqlDBWinINetConnectionProperties.Create(
        ADDR, 'root', 'user', 'pass'), 'wininet');
      {$endif USEWININET}
      {$ifdef USELIBCURL}
      DoTest(TSqlDBCurlConnectionProperties.Create(
        ADDR, 'root', 'user', 'pass'), 'libcurl');
      {$endif USELIBCURL}
    finally
      Server.Free;
    end;
  finally
    Props.Free;
  end;
end;

procedure TTestExternalDatabase.DBPropertiesPersistence;
var
  Props: TSqlDBConnectionProperties;
  json: RawUtf8;
begin
  Props := TSqlDBSQLite3ConnectionProperties.Create('server', '', '', '');
  json := Props.DefinitionToJson(14);
  Check(json = '{"Kind":"TSqlDBSQLite3ConnectionProperties",' +
    '"ServerName":"server","DatabaseName":"","User":"","Password":""}');
  Props.Free;
  Props := TSqlDBSQLite3ConnectionProperties.Create('server', '', '', '1234');
  json := Props.DefinitionToJson(14);
  Check(json = '{"Kind":"TSqlDBSQLite3ConnectionProperties",' +
    '"ServerName":"server","DatabaseName":"","User":"","Password":"MnVfJg=="}');
  Props.DefinitionToFile(WorkDir + 'connectionprops.json');
  Props.Free;
  Props := TSqlDBConnectionProperties.CreateFromFile(WorkDir + 'connectionprops.json');
  Check(Props.ClassType = TSqlDBSQLite3ConnectionProperties);
  Check(Props.ServerName = 'server');
  Check(Props.DatabaseName = '');
  Check(Props.UserID = '');
  Check(Props.PassWord = '1234');
  Props.Free;
  DeleteFile(WorkDir + 'connectionprops.json');
end;

procedure TTestExternalDatabase.CryptedDatabase;
var
  R, R2: TOrmPeople;
  Model: TOrmModel;
  aID: integer;
  Client, Client2: TRestClientDB;
  Res: TIDDynArray;

  procedure CheckFilledRow;
  begin
    Check(R.FillRewind);
    while R.FillOne do
      if not CheckFailed(R2.FillOne) then
      begin
        Check(R.ID <> 0);
        Check(R2.ID <> 0);
        Check(R.FirstName = R2.FirstName);
        Check(R.LastName = R2.LastName);
        Check(R.YearOfBirth = R2.YearOfBirth);
        Check(R.YearOfDeath = R2.YearOfDeath);
      end;
  end;

{$ifdef NOSQLITE3STATIC}
const
  password = '';
{$else}
const
  password = 'pass';
{$endif NOSQLITE3STATIC}

begin
  DeleteFile('testpass.db3');
  Model := TOrmModel.Create([TOrmPeople]);
  try
    Client := TRestClientDB.Create(Model, nil, 'test.db3', TRestServerDB, false, '');
    try
      R := TOrmPeople.Create;
      Assert(fPeopleData = nil);
      fPeopleData := Client.Client.List([TOrmPeople], '*');
      R.FillPrepare(fPeopleData);
      try
        Client2 := TRestClientDB.Create(
          Model, nil, 'testpass.db3', TRestServerDB, false, password);
        try
          Client2.Server.DB.Synchronous := smOff;
          Client2.Server.DB.LockingMode := lmExclusive;
          Client2.Server.DB.WALMode := true;
          Client2.Server.Server.CreateMissingTables;

          Check(Client2.Client.TransactionBegin(TOrmPeople));
          Check(Client2.Client.BatchStart(TOrmPeople, {autotrans=}0));
          Check(Client2.Client.BatchSend(Res) = 200, 'Void batch');
          Check(Res = nil);
          Client2.Client.Commit;
          Check(Client2.Client.TransactionBegin(TOrmPeople));
          Check(Client2.Client.BatchStart(TOrmPeople, {autotrans=}0));
          while R.FillOne do
          begin
            Check(R.ID <> 0);
            Check(Client2.Client.BatchAdd(R, true) >= 0);
          end;
          Check(Client2.Client.BatchSend(Res) = 200, 'INSERT batch');
          Client2.Client.Commit;
        finally
          Client2.Free;
        end;
        Check(IsSQLite3File('testpass.db3'));
        Check(IsSQLite3FileEncrypted('testpass.db3') = (password <> ''), 'encrypt1');
        // try to read then update the crypted file
        Client2 := TRestClientDB.Create(
          Model, nil, 'testpass.db3', TRestServerDB, false, password);
        try
          Client2.Server.DB.Synchronous := smOff;
          Client2.Server.DB.LockingMode := lmExclusive;

          R2 := TOrmPeople.CreateAndFillPrepare(Client2.Orm, '');
          try
            CheckFilledRow;
            R2.FirstName := 'One';
            aID := Client2.Orm.Add(R2, true);
            Check(aID <> 0);
            R2.FillPrepare(Client2.Orm, '');
            CheckFilledRow;
            R2.ClearProperties;
            Check(R2.FirstName = '');
            Check(Client2.Orm.Retrieve(aID, R2));
            Check(R2.FirstName = 'One');
          finally
            R2.Free;
          end;

        finally
          Client2.Free;
        end;

        Check(IsSQLite3File('testpass.db3'));
        Check(IsSQLite3FileEncrypted('testpass.db3') = (password <> ''), 'encrypt2');

        {$ifndef NOSQLITE3STATIC}

        // now read it after uncypher
        Check(ChangeSqlEncryptTablePassWord('testpass.db3', password, ''));
        Check(IsSQLite3File('testpass.db3'));
        Check(not IsSQLite3FileEncrypted('testpass.db3'), 'encrypt3');

        Client2 := TRestClientDB.Create(Model, nil, 'testpass.db3',
          TRestServerDB, false, '');
        try
          R2 := TOrmPeople.CreateAndFillPrepare(Client2.Orm, '');
          try
            CheckFilledRow;
            R2.ClearProperties;
            Check(R2.FirstName = '');
            Check(Client2.Orm.Retrieve(aID, R2));
            Check(R2.FirstName = 'One');
          finally
            R2.Free;
          end;
        finally
          Client2.Free;
        end;

        {$endif NOSQLITE3STATIC}
      finally
        R.Free;
      end;
    finally
      Client.Free;
    end;
  finally
    Model.Free;
  end;
end;

procedure TTestExternalDatabase.Test(StaticVirtualTableDirect, TrackChanges: boolean);
const
  BLOB_MAX = 1000;
var
  RInt, RInt1: TOrmPeople;
  RExt: TOrmPeopleExt;
  RBlob: TOrmOnlyBlob;
  RJoin: TOrmTestJoin;
  RHist: TOrmMyHistory;
  Tables: TRawUtf8DynArray;
  i, n, nb, aID: integer;
  Orm: TRestOrmServer;
  ok: Boolean;
  BatchID, BatchIDUpdate, BatchIDJoined: TIDDynArray;
  ids: array[0..3] of TID;
  aExternalClient: TRestClientDB;
  fProperties: TSqlDBConnectionProperties;
  json: RawUtf8;
  Start, Updated: TTimeLog; // will work with both TModTime and TCreateTime properties

  procedure HistoryCheck(aIndex, aYOB: Integer; aEvent: TOrmHistoryEvent);
  var
    Event: TOrmHistoryEvent;
    Timestamp: TModTime;
    R: TOrmPeopleExt;
  begin
    RExt.ClearProperties;
    Check(RHist.HistoryGet(aIndex, Event, Timestamp, RExt), 'get1');
    Check(Event = aEvent, 'event');
    CheckUtf8(Timestamp >= Start, '%>=%', [TimeStamp, Start]);
    if Event = heDelete then
      exit;
    CheckEqual(RExt.ID, 400, 'rext');
    CheckEqual(RExt.FirstName, 'Franz36');
    CheckEqual(RExt.YearOfBirth, aYOB);
    R := RHist.HistoryGet(aIndex) as TOrmPeopleExt;
    if CheckFailed(R <> nil, 'get2') then
      exit;
    CheckEqual(R.ID, 400, 'r');
    CheckEqual(R.FirstName, 'Franz36');
    CheckEqual(R.YearOfBirth, aYOB);
    R.Free;
  end;

  procedure HistoryChecks;
  var
    i: integer;
  begin
    RHist := TOrmMyHistory.CreateHistory(aExternalClient.Orm, TOrmPeopleExt, 400);
    try
      CheckEqual(RHist.HistoryCount, 504, 'HistoryCount');
      HistoryCheck(0, 1797, heAdd);
      HistoryCheck(1, 1828, heUpdate);
      HistoryCheck(2, 1515, heUpdate);
      for i := 1 to 500 do
        HistoryCheck(i + 2, i, heUpdate);
      HistoryCheck(503, 0, heDelete);
    finally
      RHist.Free;
    end;
  end;

var
  historyDB: TRestServerDB;
begin
  // run tests over an in-memory SQLite3 external database (much faster than file)
  DeleteFile('extdata.db3');
  fProperties := TSqlDBSQLite3ConnectionProperties.Create('extdata.db3', '', '', '');
  (fProperties.MainConnection as TSqlDBSQLite3Connection).Synchronous := smOff;
  (fProperties.MainConnection as TSqlDBSQLite3Connection).LockingMode := lmExclusive;
  Check(OrmMapExternal(fExternalModel, TOrmPeopleExt, fProperties, 'PeopleExternal').
      MapField('ID', 'Key').
      MapField('YearOfDeath', 'YOD').
      MapAutoKeywordFields <> nil);
  Check(OrmMapExternal(fExternalModel, TOrmOnlyBlob, fProperties, 'OnlyBlobExternal') <> nil);
  Check(OrmMapExternal(fExternalModel, TOrmTestJoin, fProperties, 'TestJoinExternal') <> nil);
  Check(OrmMapExternal(fExternalModel, TOrmASource,  fProperties, 'SourceExternal')   <> nil);
  Check(OrmMapExternal(fExternalModel, TOrmADest,    fProperties, 'DestExternal')     <> nil);
  Check(OrmMapExternal(fExternalModel, TOrmADests,   fProperties, 'DestsExternal')    <> nil);
  DeleteFile('testExternal.db3'); // need a file for backup testing
  if TrackChanges and
     StaticVirtualTableDirect then
  begin
    DeleteFile('history.db3');
    historyDB := TRestServerDB.Create(
      TOrmModel.Create([TOrmMyHistory], 'history'), 'history.db3', false);
  end
  else
    historyDB := nil;
  aExternalClient := TRestClientDB.Create(
    fExternalModel, nil, 'testExternal.db3', TRestServerDB);
  try
    if historyDB <> nil then
    begin
      historyDB.Model.Owner := historyDB;
      historyDB.DB.Synchronous := smOff;
      historyDB.DB.LockingMode := lmExclusive;
      historyDB.Server.CreateMissingTables;
      Check((aExternalClient.Server.OrmInstance as TRestOrmServer).
        RemoteDataCreate(TOrmMyHistory, historyDB.OrmInstance) <> nil,
          'TOrmMyHistory should not be accessed from an external process');
    end;
    aExternalClient.Server.DB.Synchronous := smOff;
    aExternalClient.Server.DB.LockingMode := lmExclusive;
    aExternalClient.Server.DB.GetTableNames(Tables);
    Check(Tables = nil, 'reset testExternal.db3 file');
    Start := aExternalClient.Client.GetServerTimestamp;
    aExternalClient.Server.Server.
      SetStaticVirtualTableDirect(StaticVirtualTableDirect);
    aExternalClient.Server.Server.CreateMissingTables;
    if TrackChanges then
      aExternalClient.Server.Server.TrackChanges(
        [TOrmPeopleExt], TOrmMyHistory, 100, 10, 65536);
    Check(aExternalClient.Server.Server.
      CreateSqlMultiIndex(TOrmPeopleExt, ['FirstName', 'LastName'], false));
    InternalTestMany(self, aExternalClient.OrmInstance as TRestOrmClientUri);
    Check(fPeopleData <> nil);
    RInt := TOrmPeople.Create;
    RInt1 := TOrmPeople.Create;
    try
      RInt.FillPrepare(fPeopleData);
      Check(RInt.FillTable <> nil);
      Check(RInt.FillTable.RowCount > 0);
      Check(not aExternalClient.Orm.TableHasRows(TOrmPeopleExt));
      CheckEqual(aExternalClient.Orm.TableRowCount(TOrmPeopleExt), 0);
      Check(not aExternalClient.Server.Orm.TableHasRows(TOrmPeopleExt));
      CheckEqual(aExternalClient.Server.Orm.TableRowCount(TOrmPeopleExt), 0);
      RExt := TOrmPeopleExt.Create;
      try
        n := 0;
        while RInt.FillOne do
        begin
          if RInt.IDValue < 100 then // some real entries for backup testing
            aExternalClient.Orm.Add(RInt, true, true);
          RExt.Data := RInt.Data;
          RExt.FirstName := RInt.FirstName;
          RExt.LastName := RInt.LastName;
          RExt.YearOfBirth := RInt.YearOfBirth;
          RExt.YearOfDeath := RInt.YearOfDeath;
          RExt.Value := ValuesToVariantDynArray(['text', RInt.YearOfDeath]);
          RExt.fLastChange := 0;
          RExt.CreatedAt := 0;
          if RInt.IDValue > 100 then
          begin
            if aExternalClient.Client.BatchCount = 0 then
              aExternalClient.Client.BatchStart(TOrmPeopleExt);
            aExternalClient.Client.BatchAdd(RExt, true);
          end
          else
          begin
            aID := aExternalClient.Orm.Add(RExt, true);
            Check(aID <> 0);
            Check(RExt.LastChange >= Start);
            Check(RExt.CreatedAt >= Start);
            RExt.ClearProperties;
            CheckEqual(RExt.YearOfBirth, 0);
            CheckEqual(RExt.FirstName, '');
            CheckEqual(pointer(RExt.Value), nil);
            Check(aExternalClient.Orm.Retrieve(aID, RExt));
            CheckEqual(RExt.FirstName, RInt.FirstName);
            CheckEqual(RExt.LastName, RInt.LastName);
            CheckEqual(RExt.YearOfBirth, RInt.YearOfBirth);
            CheckEqual(RExt.YearOfDeath, RInt.YearOfDeath);
            Check(RExt.YearOfBirth <> RExt.YearOfDeath);
            json := FormatUtf8('["text",%]', [RInt.YearOfDeath]);
            CheckEqual(VariantDynArrayToJson(RExt.Value), json);
          end;
          inc(n);
        end;
        Check(aExternalClient.Orm.Retrieve(1, RInt1));
        Check(RInt1.IDValue = 1);
        CheckEqual(n, fPeopleData.RowCount);
        CheckEqual(aExternalClient.Client.BatchSend(BatchID), HTTP_SUCCESS, 'bs');
        CheckEqual(length(BatchID), n - 99, 'bsn1');
        for i := 0 to high(BatchID) do
          CheckEqual(BatchID[i], i + 100, 'batchid');
        nb := BatchID[high(BatchID)];
        Check(aExternalClient.Orm.TableHasRows(TOrmPeopleExt));
        CheckEqual(aExternalClient.Orm.TableMaxID(TOrmPeopleExt), n);
        CheckEqual(aExternalClient.Orm.TableRowCount(TOrmPeopleExt), n);
        Check(aExternalClient.Orm.MemberExists(TOrmPeopleExt, 1));
        Check(aExternalClient.Server.Orm.TableHasRows(TOrmPeopleExt));
        CheckEqual(aExternalClient.Server.Orm.TableMaxID(TOrmPeopleExt), n);
        CheckEqual(aExternalClient.Server.Orm.TableRowCount(TOrmPeopleExt), n);
        Check(aExternalClient.Server.Orm.MemberExists(TOrmPeopleExt, 1));
        Check(RInt.FillRewind);
        while RInt.FillOne do
        begin
          RExt.FillPrepare(aExternalClient.Orm, 'FirstName=? and LastName=?',
            [RInt.FirstName, RInt.LastName]); // query will use index -> fast :)
          while RExt.FillOne do
          begin
            CheckEqual(RExt.FirstName, RInt.FirstName);
            CheckEqual(RExt.LastName, RInt.LastName);
            CheckEqual(RExt.YearOfBirth, RInt.YearOfBirth);
            CheckEqual(RExt.YearOfDeath, RInt.YearOfDeath);
            Check(RExt.YearOfBirth <> RExt.YearOfDeath);
            CheckEqual(VariantDynArrayToJson(RExt.Value),
              FormatUtf8('["text",%]', [RInt.YearOfDeath]));
          end;
        end;
        Updated := aExternalClient.Orm.GetServerTimestamp;
        Check(Updated >= Start);
        CheckEqual(nb, BatchID[high(BatchID)]);
        for i := 1 to nb do
          if i mod 100 = 0 then
          begin
            RExt.fLastChange := 0;
            RExt.CreatedAt := 0;
            RExt.Value := nil;
            Check(aExternalClient.Orm.Retrieve(i, RExt, true), 'for update');
            Check(RExt.YearOfBirth <> RExt.YearOfDeath);
            Check(RExt.CreatedAt <= Updated);
            CheckEqual(VariantDynArrayToJson(RExt.Value),
              FormatUtf8('["text",%]', [RExt.YearOfDeath]));
            RExt.YearOfBirth := RExt.YearOfDeath; // YOB=YOD for 1/100 rows
            if i > 4000 then
            begin
              if aExternalClient.Client.BatchCount = 0 then
                aExternalClient.Client.BatchStart(TOrmPeopleExt);
              Check(aExternalClient.Client.BatchUpdate(RExt) >= 0,
                'BatchUpdate 1/100 rows');
            end
            else
            begin
              Check(aExternalClient.Client.Update(RExt), 'Update 1/100 rows');
              Check(aExternalClient.Client.UnLock(RExt));
              Check(RExt.LastChange >= Updated);
              RExt.ClearProperties;
              CheckEqual(pointer(RExt.Value), nil);
              CheckEqual(RExt.YearOfDeath, 0);
              CheckEqual(RExt.YearOfBirth, 0);
              CheckEqual(RExt.CreatedAt, 0);
              Check(aExternalClient.Client.Retrieve(i, RExt), 'after update');
              CheckEqual(RExt.YearOfBirth, RExt.YearOfDeath);
              Check(RExt.CreatedAt >= Start);
              Check(RExt.CreatedAt <= Updated);
              Check(RExt.LastChange >= Updated);
              CheckEqual(VariantDynArrayToJson(RExt.Value),
                FormatUtf8('["text",%]', [RExt.YearOfDeath]));
            end;
          end;
        Check(aExternalClient.Client.BatchSend(BatchIDUpdate) = HTTP_SUCCESS);
        Check(length(BatchIDUpdate) = 70);
        CheckEqual(nb, BatchID[high(BatchID)]);
        for i := 1 to nb do
          if i and 127 = 0 then
            if i > 4000 then
            begin
              if aExternalClient.Client.BatchCount = 0 then
                aExternalClient.Client.BatchStart(TOrmPeopleExt);
              Check(aExternalClient.Client.BatchDelete(i) >= 0,
                'BatchDelete 1/128 rows');
            end
            else
              Check(aExternalClient.Client.Delete(TOrmPeopleExt, i),
                'Delete 1/128 rows');
        CheckEqual(aExternalClient.Client.BatchSend(BatchIDUpdate), HTTP_SUCCESS);
        CheckEqual(length(BatchIDUpdate), 55);
        n := aExternalClient.Client.TableRowCount(TOrmPeople); // check below
        CheckEqual(aExternalClient.Server.Server.TableRowCount(TOrmPeopleExt), 10925);
        Orm := aExternalClient.Server.OrmInstance as TRestOrmServer;
        CheckEqual(Orm.GetVirtualStorage(TOrmPeople), nil);
        Check(Orm.GetVirtualStorage(TOrmPeopleExt) <> nil);
        Check(Orm.GetVirtualStorage(TOrmOnlyBlob) <> nil);
        CheckEqual(nb, BatchID[high(BatchID)]);
        for i := 1 to nb do
        begin
          RExt.fLastChange := 0;
          RExt.CreatedAt := 0;
          RExt.YearOfBirth := 0;
          ok := aExternalClient.Client.Retrieve(i, RExt, false);
          Check(ok = (i and 127 <> 0), 'deletion');
          if not ok then
            continue;
          CheckEqual(VariantDynArrayToJson(RExt.Value),
            FormatUtf8('["text",%]', [RExt.YearOfDeath]));
          Check(RExt.CreatedAt >= Start);
          Check(RExt.CreatedAt <= Updated);
          if i mod 100 = 0 then
          begin
            CheckEqual(RExt.YearOfBirth, RExt.YearOfDeath, 'Update1');
            CheckUtf8(RExt.LastChange >= Updated, 'LastChange1 %>=%',
              [RExt.LastChange, Updated]);
          end
          else
          begin
            Check(RExt.YearOfBirth <> RExt.YearOfDeath, 'Update2');
            Check(RExt.LastChange >= Start);
            CheckUtf8(RExt.LastChange <= Updated, 'LastChange2 %<=%',
              [RExt.LastChange, Updated]);
          end;
        end;
        aExternalClient.Client.Retrieve(400, RExt);
        CheckEqual(RExt.IDValue, 400);
        CheckEqual(RExt.FirstName, 'Franz36');
        CheckEqual(RExt.YearOfBirth, 1828);
        aExternalClient.Client.UpdateField(
          TOrmPeopleExt, 400, 'YearOfBirth', [1515]);
        RInt1.ClearProperties;
        Check(aExternalClient.Client.Retrieve(1, RInt1));
        CheckEqual(RInt1.IDValue, 1);
        for i := 0 to high(ids) do
        begin
          RExt.YearOfBirth := i;
          ids[i] := aExternalClient.Orm.Add(RExt, true);
        end;
        for i := 0 to high(ids) do
        begin
          Check(aExternalClient.Orm.Retrieve(ids[i], RExt));
          CheckEqual(RExt.YearOfBirth, i);
        end;
        for i := 0 to high(ids) do
        begin
          aExternalClient.Client.BatchStart(TOrmPeopleExt, {autotrans=}0);
          aExternalClient.Client.BatchDelete(ids[i]);
          CheckEqual(aExternalClient.Client.BatchSend(BatchID), HTTP_SUCCESS);
          CheckEqual(length(BatchID), 1);
          CheckEqual(BatchID[0], HTTP_SUCCESS);
        end;
        for i := 0 to high(ids) do
          Check(not aExternalClient.Orm.Retrieve(ids[i], RExt));
        RExt.ClearProperties;
        for i := 0 to high(ids) do
        begin
          RExt.IDValue := ids[i];
          Check(aExternalClient.Orm.Update(RExt), 'test locking');
        end;
      finally
        RExt.Free;
      end;
      RJoin := TOrmTestJoin.Create;
      try
        aExternalClient.Client.BatchStart(TOrmTestJoin, 1000);
        for i := 1 to BLOB_MAX do
          if i and 127 <> 0 then
          begin
            RJoin.Name := Int32ToUTF8(i);
            RJoin.People := TOrmPeopleExt(i);
            aExternalClient.Client.BatchAdd(RJoin, true);
          end;
        CheckEqual(aExternalClient.Client.BatchSend(BatchIDJoined), HTTP_SUCCESS);
        CheckEqual(length(BatchIDJoined), 993);
        RJoin.FillPrepare(aExternalClient.Orm);
        CheckEqual(RJoin.FillTable.RowCount, 993);
        i := 1;
        while RJoin.FillOne do
        begin
          if i and 127 = 0 then
            inc(i); // deleted item
          CheckEqual(GetInteger(pointer(RJoin.Name)), i);
          CheckEqual(RJoin.People.ID, i, 'retrieve ID from pointer');
          inc(i);
        end;
      finally
        RJoin.Free;
      end;
      for i := 0 to high(BatchIDJoined) do
      begin
        RJoin := TOrmTestJoin.CreateJoined(aExternalClient.Orm, BatchIDJoined[i]);
        try
          Check(RJoin.FillTable.FieldType(0) = oftInteger);
          Check(RJoin.FillTable.FieldType(3) = oftUTF8Text);
          CheckEqual(RJoin.ID, BatchIDJoined[i]);
          Check(PtrUInt(RJoin.People) > 1000);
          CheckEqual(GetInteger(pointer(RJoin.Name)), RJoin.People.ID);
          CheckEqual(length(RJoin.People.Value), 2);
          Check(RJoin.People.Value[0] = 'text');
          Check(RJoin.People.Value[1] = RJoin.People.YearOfDeath);
          RJoin.ClearProperties;
          CheckEqual(RJoin.ID, 0);
          CheckEqual(RJoin.People.ID, 0);
        finally
          RJoin.Free;
        end;
      end;
      Check(not aExternalClient.Server.Orm.TableHasRows(TOrmOnlyBlob));
      CheckEqual(aExternalClient.Server.Orm.TableRowCount(TOrmOnlyBlob), 0);
      RBlob := TOrmOnlyBlob.Create;
      try
        aExternalClient.Client.ForceBlobTransfertTable[TOrmOnlyBlob] := true;
        aExternalClient.Orm.TransactionBegin(TOrmOnlyBlob);
        for i := 1 to BLOB_MAX do
        begin
          RBlob.Data := Int32ToUtf8(i);
          CheckEqual(aExternalClient.Orm.Add(RBlob, true), i);
          CheckEqual(RBlob.ID, i);
        end;
        aExternalClient.Orm.Commit;
        for i := 1 to BLOB_MAX do
        begin
          Check(aExternalClient.Orm.Retrieve(i, RBlob));
          CheckEqual(GetInteger(pointer(RBlob.Data)), i);
        end;
        aExternalClient.Orm.TransactionBegin(TOrmOnlyBlob);
        for i := BLOB_MAX downto 1 do
        begin
          RBlob.IDValue := i;
          RBlob.Data := Int32ToUtf8(i * 2);
          Check(aExternalClient.Orm.Update(RBlob));
        end;
        aExternalClient.Orm.Commit;
        for i := 1 to BLOB_MAX do
        begin
          Check(aExternalClient.Orm.Retrieve(i, RBlob));
          CheckEqual(GetInteger(pointer(RBlob.Data)), i * 2);
        end;
        aExternalClient.Client.ForceBlobTransfertTable[TOrmOnlyBlob] := false;
        RBlob.ClearProperties;
        for i := 1 to BLOB_MAX do
        begin
          Check(aExternalClient.Orm.Retrieve(i, RBlob));
          CheckEqual(RBlob.Data, '');
        end;
      finally
        RBlob.Free;
      end;
      Check(aExternalClient.Orm.TableHasRows(TOrmOnlyBlob));
      CheckEqual(aExternalClient.Orm.TableRowCount(TOrmOnlyBlob), 1000);
      CheckEqual(aExternalClient.Orm.TableRowCount(TOrmPeople), n);
      RInt1.ClearProperties;
      Orm := aExternalClient.Server.OrmInstance as TRestOrmServer;
      Check(Orm.GetVirtualStorage(TOrmPeople) = nil);
      Check(Orm.GetVirtualStorage(TOrmPeopleExt) <> nil);
      Check(Orm.GetVirtualStorage(TOrmOnlyBlob) <> nil);
      Check(aExternalClient.Orm.TableHasRows(TOrmPeople));
      CheckEqual(aExternalClient.Orm.TableRowCount(TOrmPeople), n);
      RInt1.ClearProperties;
      aExternalClient.Orm.Retrieve(1, RInt1);
      CheckEqual(RInt1.IDValue, 1);
      CheckEqual(RInt1.FirstName, 'Salvador1');
      CheckEqual(RInt1.YearOfBirth, 1904);
    finally
      RInt.Free;
      RInt1.Free;
    end;
    if TrackChanges then
    begin
      RExt := TOrmPeopleExt.Create;
      try
        RHist := TOrmMyHistory.CreateHistory(
          aExternalClient.Orm, TOrmPeopleExt, 400);
        try
          Check(RHist.HistoryCount = 3);
          HistoryCheck(0, 1797, heAdd);
          HistoryCheck(1, 1828, heUpdate);
          HistoryCheck(2, 1515, heUpdate);
        finally
          RHist.Free;
        end;
        for i := 1 to 500 do
        begin
          RExt.YearOfBirth := i;
          aExternalClient.Orm.Update(RExt, 'YearOfBirth');
        end;
        aExternalClient.Orm.Delete(TOrmPeopleExt, 400);
        HistoryChecks;
        aExternalClient.Server.Server.TrackChangesFlush(TOrmMyHistory);
        HistoryChecks;
      finally
        RExt.Free;
      end;
    end;
  finally
    aExternalClient.Free;
    fProperties.Free;
    historyDB.Free;
  end;
end;

end.


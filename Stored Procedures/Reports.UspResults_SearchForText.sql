
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO
CREATE Proc [Reports].[UspResults_SearchForText]
    (
      @TextToSearch NVarchar(Max)
    , @DBToSearch NVarchar(500)
    , @SchemaToSearch NVarchar(500)
    , @ObjectName NVarchar(500)
    , @TableView Varchar(10)
    , @ShowStats Bit
    , @IncludeExecErrors Bit
    )
As
    Begin
        Set NoCount On;
        Declare @StartDate DateTime2 = GetDate();
        Declare @SQLScript NVarchar(Max);
        Set @TextToSearch = '%' + Coalesce(@TextToSearch , '') + '%';
        Set @DBToSearch = '%' + Coalesce(@DBToSearch , '') + '%';
        Set @SchemaToSearch = '%' + Coalesce(@SchemaToSearch , '') + '%';
        Set @ObjectName = '%' + Coalesce(@ObjectName , '') + '%';
        Set @TableView = Coalesce(@TableView , 'Both');

        Create Table [#ObjectList]
            (
              [object_id] Int Not Null
            , [ObjectName] sysname
            , [ObjectType] Varchar(10)
            , [SchemaName] sysname
            , [DBName] Varchar(255) Not Null
            , [ObjectDefinition] NVarchar(Max)
			, Constraint [PK_ObjList_ObjectID_DBName] Primary Key ([object_id],[DBName])
            );
        --Alter Table [#ObjectList] Add Constraint [PK_ObjList_ObjectID_DBName] Primary Key ([object_id],[DBName]);
        Create Table [#ColumnList]
            (
              [object_id] Int Not Null
            , [ColumnID] Int Not Null
            , [ColumnName] sysname
            , [ColumnType] TinyInt
            , [max_length] Smallint
            , [DBName] Varchar(255) Not Null
            , [ExecID] Int Identity(1 , 1)
			, Constraint [PL_ColList_ObjectID_ColID_DBName] Primary Key ([object_id],[ColumnID],[DBName])
            );
        --Alter Table [#ColumnList] Add Constraint [PL_ColList_ObjectID_ColID_DBName] Primary Key ([object_id],[ColumnID],[DBName]);

--Get list of table or views
        If @TableView In ( 'Table' , 'Both' )
            Begin
                Set @SQLScript = 'Use [?]; 
			Declare @DB Varchar(250)= Db_Name();
			Insert [#ObjectList]
					( [object_id]
					, [ObjectName]
					, [ObjectType]
					, [SchemaName]
					, [DBName]
					, [ObjectDefinition]
					)
			Select  [T].[object_id]
				  , ObjectName = [T].[name]
				  , ObjectType = ''Table''
				  , SchemaName = [S].[name]
				  , DBName = @DB
				  , [ObjectDefinition]=null --Object_Definition([T].[object_id])
			From    [sys].[tables] As [T]
					Left Join [sys].[schemas] As [S] On [S].[schema_id] = [T].[schema_id];';

                Exec [Process].[ExecForEachDB] @cmd = @SQLScript;

            End;
        If @TableView In ( 'View' , 'Both' )
            Begin
                Set @SQLScript = 'Use [?]; 
			Declare @DB Varchar(250)= Db_Name();
			Insert [#ObjectList]
					( [object_id]
					, [ObjectName]
					, [ObjectType]
					, [SchemaName]
					, [DBName]
					, [ObjectDefinition]
					)
			Select  [V].[object_id]
				  , ObjectName = [V].[name]
				  , ObjectType = ''View''
				  , SchemaName = [S].[name]
				  , DBName = @DB
				  , Object_Definition([V].[object_id])
			From    [sys].[views]  As [V]
					Left Join [sys].[schemas] As [S] On [S].[schema_id] = [V].[schema_id];';

                Exec [Process].[ExecForEachDB] @cmd = @SQLScript;

            End;

--get list of columns
        Set @SQLScript = 'Use [?]; 
	Declare @DB Varchar(250)= Db_Name();
	if @DB not in(''tempdb'',''master'',''model'',''msdb'')
	begin
		Insert [#ColumnList]
				( [object_id]
				, [ColumnID]
				, [ColumnName]
				, [ColumnType]
				, [max_length]
				, [DBName]
				)
		SELECT [C].[object_id]
				,[C].[column_id]
				,[C].[name]
				,[C].[system_type_id]
				,[max_length]
				,@DB
		 FROM sys.[columns] As [C];
	end';
        Exec [sys].[sp_MSforeachdb] @SQLScript;

--Remove fields that are too small, not in the right db or schema and are not a text type field
        Delete  [#ColumnList]
        From    [#ColumnList] As [C]
                Left Join [#ObjectList] As [OL] On [OL].[object_id] = [C].[object_id]
                Left Join [sys].[types] As [T] On [C].[ColumnType] = [T].[system_type_id]
        Where   [C].[max_length] < Len(@TextToSearch)
                Or Upper([OL].[DBName]) Not Like Upper(@DBToSearch)
                Or Upper([OL].[ObjectName]) Not Like Upper(@ObjectName)
                Or Upper([OL].[SchemaName]) Not Like Upper(@SchemaToSearch)
                Or [T].[name] Not In ( 'text' , 'ntext' , 'varchar' , 'char' ,
                                       'nvarchar' , 'nchar' , 'xml' ,
                                       'sysname' )
                Or [OL].[object_id] Is Null;

        /*Alter Table [#ColumnList] 
        Add [ExecID] Int Identity(1,1);*/

        Declare @CurrentID Int
          , @MaxID Int
          , @CurrentCount Int;
		
        Create NonClustered Index [ColList_ExID_ColName_ObjID_DB] On [#ColumnList] ([ExecID],[ColumnName],[object_id],[DBName]);
        Create NonClustered Index [ObjList_ObjID_ObName_Schema_DB] On [#ObjectList] ([object_id],[ObjectName],[SchemaName],[DBName]);

        Create Table [#Results]
            (
              [ColumnName] sysname
            , [TableName] sysname
            , [SchemaName] sysname
            , [DBName] Varchar(250)
            , [CountofMatchingRows] Int
            , [MaxMatchingRow] NVarchar(Max)
            , [MinMatchingRow] NVarchar(Max)
            );

        Select  @CurrentID = Min([CL].[ExecID])
        From    [#ColumnList] As [CL];

        Select  @MaxID = Max([CL].[ExecID])
        From    [#ColumnList] As [CL];

        If @ShowStats = 1
            Begin
                Print 'Columns to check ' + Convert(NVarchar(50) , @MaxID);
            End;

        Declare @CurrentIDtxt NVarchar(50)
          , @CurrentPerct Numeric(20 , 2)
          , @CurrentPerctTxt NVarchar(50)
          , @TimeSpent Numeric(20 , 2)
          , @TimeSpentTxt NVarchar(50)
          , @TimeRemaining Numeric(20 , 2)
          , @TimeRemainingTxt NVarchar(50)
          , @TimeOffset Numeric(20 , 2);

		--time offset removes initial load time
        Select  @TimeOffset = DateDiff(Second , @StartDate , GetDate());

        While @CurrentID <= @MaxID
            Begin
                Select  @SQLScript = 'Insert [#Results]
						( [ColumnName]
						, [TableName]
						, [SchemaName]
						, [DBName]
						, [CountofMatchingRows]
						, [MaxMatchingRow]
						, [MinMatchingRow]
						)
						Select [ColumnName]=''' + [CL].[ColumnName] + '''
						, [TableName]=''' + [OL].[ObjectName] + '''
						, [SchemaName]=''' + [OL].[SchemaName] + '''
						, [DBName]=''' + [CL].[DBName] + '''
						, [CountofMatchingRows] = count(1)
						, [MaxMatchingRow] = convert(Nvarchar(max),max('
                        + QuoteName([CL].[ColumnName]) + '))
						, [MinMatchingRow] = convert(Nvarchar(max),min('
                        + QuoteName([CL].[ColumnName]) + '))
						from ' + QuoteName([CL].[DBName]) + '.'
                        + QuoteName([OL].[SchemaName]) + '.'
                        + QuoteName([OL].[ObjectName]) + '
						where lower(' + QuoteName([CL].[ColumnName])
                        + ') collate Latin1_General_CI_AI like lower('''
                        + @TextToSearch + ''') collate Latin1_General_CI_AI
						having count(1)>0'
                From    [#ColumnList] As [CL]
                        Left Join [#ObjectList] As [OL] On [OL].[object_id] = [CL].[object_id]
                                                           And [OL].[DBName] = [CL].[DBName]
                Where   [CL].[ExecID] = @CurrentID;		
		
                Begin Try
                    Exec (@SQLScript);
                End Try
                Begin Catch
                    If @IncludeExecErrors = 1
                        Begin
                            Insert  [#Results]
                                    ( [ColumnName]
                                    , [TableName]
                                    , [SchemaName]
                                    , [DBName]
                                    , [CountofMatchingRows]
                                    , [MaxMatchingRow]
                                    , [MinMatchingRow]
		                            )
                                    Select  [CL].[ColumnName]
                                          , [OL].[ObjectName]
                                          , [OL].[SchemaName]
                                          , [CL].[DBName]
                                          , 0
                                          , 'Unable to execute against'
                                          , 'Unable to execute against'
                                    From    [#ColumnList] As [CL]
                                            Left Join [#ObjectList] As [OL] On [OL].[object_id] = [CL].[object_id]
                                                              And [OL].[DBName] = [CL].[DBName]
                                    Where   [CL].[ExecID] = @CurrentID;	
                        End;
                End Catch;
                If @ShowStats = 1
                    Begin
                        If @CurrentID % 1000 = 0
                            Begin
                                Set @CurrentIDtxt = Convert(NVarchar(50) , @CurrentID);
                                Set @CurrentPerct = @CurrentID
                                    / Convert(Numeric(20 , 2) , @MaxID) * 100;
                                Set @CurrentPerctTxt = Convert(NVarchar(50) , @CurrentPerct);
                                Set @TimeSpent = DateDiff(Second , @StartDate ,
                                                          GetDate())
                                    - @TimeOffset;
                                Set @TimeSpentTxt = Convert(NVarchar(50) , @TimeSpent);
                                Set @TimeRemaining = ( @TimeSpent
                                                       / @CurrentPerct * 100 )
                                    - @TimeSpent;
                                Set @TimeRemainingTxt = Convert(NVarchar(50) , @TimeRemaining);

                                Print @CurrentIDtxt + ' Columns checked - '
                                    + @CurrentPerctTxt + '% - Time spent '
                                    + @TimeSpentTxt
                                    + ' Seconds - estimated remaining Time '
                                    + @TimeRemainingTxt + ' Seconds';
                            End;
                    End;
                Delete  [#ColumnList]
                Where   [ExecID] = @CurrentID;

                Select  @CurrentID = Min([CL].[ExecID])
                From    [#ColumnList] As [CL];
            End;

        Select  [DBName] = QuoteName([R].[DBName])
              , [Dot1] = '.'
              , [SchemaName] = QuoteName([R].[SchemaName])
              , [Dot2] = '.'
              , [TableName] = QuoteName([R].[TableName])
              , [ColumnName] = QuoteName([R].[ColumnName])
              , [Script] = 'SELECT * FROM ' + QuoteName([R].[DBName]) + '.'
                + QuoteName([R].[SchemaName]) + '.'
                + QuoteName([R].[TableName]) + '
where ' + QuoteName([R].[ColumnName]) + ' like '''
                + @TextToSearch + ''''
              , [R].[CountofMatchingRows]
              , [R].[MaxMatchingRow]
              , [R].[MinMatchingRow]
        From    [#Results] As [R]
        Order By [R].[CountofMatchingRows] Desc;

        Drop Table [#ObjectList];
        Drop Table [#ColumnList];
        Drop Table [#Results];
    End;
GO

--Remove Logs
Truncate Table [History].[RedTagLogs]

--Show Tags without entries
Exec [Reports].UspResults_RedTagDetails

--Run test to add entries
EXEC	[dbo].[TestProcedure]@TextToRun = N'Print ''?''',
		@RedTagType = N'M',
		@RedTagUse = N'Testing'

--Show tags with entries
Exec [Reports].UspResults_RedTagDetails
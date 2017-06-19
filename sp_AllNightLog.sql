SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

IF OBJECT_ID('dbo.sp_AllNightLog') IS NULL
  EXEC ('CREATE PROCEDURE dbo.sp_AllNightLog AS RETURN 0;')
GO


ALTER PROCEDURE dbo.sp_AllNightLog
	  @PollForNewDatabases BIT = 0, /* Formerly Pollster */
	  @Backup BIT = 0, /* Formerly LogShaming */
	  @Restore BIT = 0,
	  @Debug BIT = 0,
	  @Help BIT = 0,
	  @VersionDate DATETIME = NULL OUTPUT
WITH RECOMPILE
AS
SET NOCOUNT ON;

BEGIN;


IF @Help = 1

BEGIN

	PRINT '		
		/*


		sp_AllNightLog from http://FirstResponderKit.org
		
		* @PollForNewDatabases = 1 polls sys.databases for new entries
			* Unfortunately no other way currently to automate new database additions when restored from backups
				* No triggers or extended events that easily do this
	
		* @Backup = 1 polls msdbCentral.dbo.backup_worker for databases not backed up in [RPO], takes LOG backups
			* Will switch to a full backup if none exists
	
	
		To learn more, visit http://FirstResponderKit.org where you can download new
		versions for free, watch training videos on how it works, get more info on
		the findings, contribute your own code, and more.
	
		Known limitations of this version:
		 - Only Microsoft-supported versions of SQL Server. Sorry, 2005 and 2000! And really, maybe not even anything less than 2016. Heh.
	
		Unknown limitations of this version:
		 - None.  (If we knew them, they would be known. Duh.)
	
	     Changes - for the full list of improvements and fixes in this version, see:
	     https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/
	
	
		Parameter explanations:
	
		  @PollForNewDatabases BIT, defaults to 0. When this is set to 1, runs in a perma-loop to find new entries in sys.databases 
		  @Backup BIT, defaults to 0. When this is set to 1, runs in a perma-loop checking the backup_worker table for databases that need to be backed up
		  @Debug BIT, defaults to 0. Whent this is set to 1, it prints out dynamic SQL commands
		  @RPOSeconds BIGINT, defaults to 30. Value in seconds you want to use to determine if a new log backup needs to be taken.
		  @BackupPath NVARCHAR(MAX), defaults to = ''D:\Backup''. You 99.99999% will need to change this path to something else. This tells Ola''s job where to put backups.
	
		For more documentation: https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/
	
	    MIT License
		
		Copyright (c) 2017 Brent Ozar Unlimited
	
		Permission is hereby granted, free of charge, to any person obtaining a copy
		of this software and associated documentation files (the "Software"), to deal
		in the Software without restriction, including without limitation the rights
		to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
		copies of the Software, and to permit persons to whom the Software is
		furnished to do so, subject to the following conditions:
	
		The above copyright notice and this permission notice shall be included in all
		copies or substantial portions of the Software.
	
		THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
		IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
		FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
		AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
		LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
		OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
		SOFTWARE.


		*/';

RETURN
END


SET NOCOUNT ON;

DECLARE @Version VARCHAR(30);
SET @Version = '1.0';
SET @VersionDate = '20170611';

DECLARE	@database NVARCHAR(128) = NULL; --Holds the database that's currently being processed
DECLARE @error_number INT = NULL; --Used for TRY/CATCH
DECLARE @error_severity INT; --Used for TRY/CATCH
DECLARE @error_state INT; --Used for TRY/CATCH
DECLARE @msg NVARCHAR(4000) = N''; --Used for RAISERROR
DECLARE @rpo INT; --Used to hold the RPO value in our configuration table
DECLARE @backup_path NVARCHAR(MAX); --Used to hold the backup path in our configuration table
DECLARE @db_sql NVARCHAR(MAX) = N''; --Used to hold the dynamic SQL to create msdbCentral
DECLARE @tbl_sql NVARCHAR(MAX) = N''; --Used to hold the dynamic SQL that creates tables in msdbCentral
DECLARE @database_name NVARCHAR(256) = N'msdbCentral'; --Used to hold the name of the database we create to centralize data
													   --Right now it's hardcoded to msdbCentral, but I made it dynamic in case that changes down the line




/*

Make sure we're doing something

*/

IF (
		  @PollForNewDatabases = 0
	  AND @Backup = 0
	  AND @Restore = 0
	  AND @Help = 0
)
		BEGIN 		
			RAISERROR('You don''t seem to have picked an action for this stored procedure to take.', 0, 1) WITH NOWAIT
			
			RETURN;
		END 



/*

Certain variables necessarily skip to parts of this script that are irrelevant
in both directions to each other. They are used for other stuff.

*/


/*

Pollster use happens strictly to check for new databases in sys.databases to place them in a worker queue

*/

IF @PollForNewDatabases = 1
	GOTO Pollster;

/*

LogShamer happens when we need to find and assign work to a worker job

*/

IF @Backup = 1
	GOTO LogShamer;


/*

Begin Polling section

*/



/*

This section runs in a loop checking for new databases added to the server, or broken backups

*/


Pollster:

	IF @Debug = 1 RAISERROR('Beginning Pollster', 0, 1) WITH NOWAIT;
	
	IF OBJECT_ID('msdbCentral.dbo.backup_worker') IS NOT NULL
	
		BEGIN
		
			WHILE @PollForNewDatabases = 1
			
			BEGIN
				
				BEGIN TRY
			
					IF @Debug = 1 RAISERROR('Checking for new databases...', 0, 1) WITH NOWAIT;

					/*
					
					Look for new non-system databases -- there should probably be additional filters here for accessibility, etc.

					*/
	
						INSERT msdbCentral.dbo.backup_worker (database_name) 
						SELECT d.name
						FROM sys.databases d
						WHERE NOT EXISTS (
							SELECT 1 
							FROM msdbCentral.dbo.backup_worker bw
							WHERE bw.database_name = d.name
										)
						AND d.database_id > 4;

						IF @Debug = 1 RAISERROR('Checking for wayward databases', 0, 1) WITH NOWAIT;

						/*
							
						This section aims to find databases that have
							* Had a log backup ever (the default for finish time is 9999-12-31, so anything with a more recent finish time has had a log backup)
							* Not had a log backup start in the last 5 minutes (this could be trouble! or a really big log backup)
							* Also checks msdb.dbo.backupset to make sure the database has a full backup associated with it (otherwise it's the first full, and we don't need to start taking log backups yet)

						*/
	
						IF EXISTS (
								
							SELECT 1
							FROM msdbCentral.dbo.backup_worker bw WITH (READPAST)
							WHERE bw.last_log_backup_finish_time < '99991231'
							AND bw.last_log_backup_start_time < DATEADD(MINUTE, -5, GETDATE())				
							AND EXISTS (
									SELECT 1
									FROM msdb.dbo.backupset b
									WHERE b.database_name = bw.database_name
									AND b.type = 'D'
										)								
								)
	
							BEGIN
									
								IF @Debug = 1 RAISERROR('Resetting databases with a log backup and no log backup in the last 5 minutes', 0, 1) WITH NOWAIT;

	
									UPDATE bw
											SET bw.is_started = 0,
												bw.is_completed = 1,
												bw.last_log_backup_start_time = '19000101'
									FROM msdbCentral.dbo.backup_worker bw
									WHERE bw.last_log_backup_finish_time < '99991231'
									AND bw.last_log_backup_start_time < DATEADD(MINUTE, -5, GETDATE())
									AND EXISTS (
											SELECT 1
											FROM msdb.dbo.backupset b
											WHERE b.database_name = bw.database_name
											AND b.type = 'D'
												);

								
								END; --End check for wayward databases

						/*
						
						Wait 1 minute between runs, we don't need to be checking this constantly
						
						*/

	
					IF @Debug = 1 RAISERROR('Waiting for 1 minute', 0, 1) WITH NOWAIT;
					
					WAITFOR DELAY '00:01:00.000';

				END TRY

				BEGIN CATCH


						SELECT @msg = N'Error inserting databases to msdbCentral.dbo.backup_worker, error number is ' + CONVERT(NVARCHAR(10), ERROR_NUMBER()) + ', error message is ' + ERROR_MESSAGE(), 
							   @error_severity = ERROR_SEVERITY(), 
							   @error_state = ERROR_STATE();
						
						RAISERROR(@msg, @error_severity, @error_state) WITH NOWAIT;

	
						WHILE @@TRANCOUNT > 0
							ROLLBACK;


				END CATCH;
	
			
			END; 
		
		END;-- End Pollster loop
	
		ELSE
	
			BEGIN
	
				RAISERROR('msdbCentral.dbo.backup_worker does not exist, please create it.', 0, 1) WITH NOWAIT;
				RETURN;
			
			END; 
	RETURN;


/*

End of Pollster

*/



/*

Begin LogShamer

*/

LogShamer:

	IF @Debug = 1 RAISERROR('Beginning Backups', 0, 1) WITH NOWAIT;
	
	IF OBJECT_ID('msdbCentral.dbo.backup_worker') IS NOT NULL
	
		BEGIN
		
			/*
			
			Make sure configuration table exists...
			
			*/
	
			IF OBJECT_ID('msdbCentral.dbo.backup_configuration') IS NOT NULL
	
				BEGIN
	
					IF @Debug = 1 RAISERROR('Checking variables', 0, 1) WITH NOWAIT;
		
			/*
			
			These settings are configurable
	
			I haven't found a good way to find the default backup path that doesn't involve xp_regread
			
			*/
	
						SELECT @rpo  = CONVERT(INT, configuration_setting)
						FROM msdbCentral.dbo.backup_configuration c
						WHERE configuration_name = N'log backup frequency';
	
							
							IF @rpo IS NULL
								BEGIN
									RAISERROR('@rpo cannot be NULL. Please check the msdbCentral.dbo.backup_configuration table', 0, 1) WITH NOWAIT;
									RETURN;
								END;	
	
	
						SELECT @backup_path = CONVERT(NVARCHAR(512), configuration_setting)
						FROM msdbCentral.dbo.backup_configuration c
						WHERE configuration_name = N'log backup path';
	
							
							IF @backup_path IS NULL
								BEGIN
									RAISERROR('@backup_path cannot be NULL. Please check the msdbCentral.dbo.backup_configuration table', 0, 1) WITH NOWAIT;
									RETURN;
								END;	
	
				END;
	
			ELSE
	
				BEGIN
	
					RAISERROR('msdbCentral.dbo.backup_configuration does not exist, please run setup script', 0, 1) WITH NOWAIT;
					RETURN;
				
				END;
	
	
			WHILE @Backup = 1

			/*
			
			Start loop to take log backups
			*/

			
				BEGIN
	
					BEGIN TRY
							
							BEGIN TRAN;
	
								IF @Debug = 1 RAISERROR('Begin tran to grab a database', 0, 1) WITH NOWAIT;


								/*
								
								This grabs a database for a worker to work on

								The locking hints hope to provide some isolation when 10+ workers are in action
								
								*/
	
							
										SELECT TOP (1) 
												@database = bw.database_name
										FROM msdbCentral.dbo.backup_worker bw WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
										WHERE 
											  (		/*This section works on databases already part of the backup cycle*/
												    bw.is_started = 0
												AND bw.is_completed = 1
												AND bw.last_log_backup_start_time < DATEADD(SECOND, (@rpo * -1), GETDATE()) 
											  )
										OR    
											  (		/*This section picks up newly added databases by Pollster*/
											  	    bw.is_started = 0
											  	AND bw.is_completed = 0
											  	AND bw.last_log_backup_start_time = '1900-01-01 00:00:00.000'
											  	AND bw.last_log_backup_finish_time = '9999-12-31 00:00:00.000'
											  )
										ORDER BY bw.last_log_backup_start_time ASC, bw.last_log_backup_finish_time ASC, bw.database_name ASC;
	
								
									IF @database IS NOT NULL
										BEGIN
										SET @msg = N'Updating backup_worker for database ' + ISNULL(@database, 'UH OH NULL @database');
										IF @Debug = 1 RAISERROR(@msg, 0, 1) WITH NOWAIT;
								
										/*
								
										Update the worker table so other workers know a database is being backed up
								
										*/

								
										UPDATE bw
												SET bw.is_started = 1,
													bw.is_completed = 0,
													bw.last_log_backup_start_time = GETDATE()
										FROM msdbCentral.dbo.backup_worker bw 
										WHERE bw.database_name = @database;
										END
	
							COMMIT;
	
					END TRY
	
					BEGIN CATCH
						
						/*
						
						Do I need to build retry logic in here? Try to catch deadlocks? I don't know yet!
						
						*/

						SELECT @msg = N'Error securing a database to backup, error number is ' + CONVERT(NVARCHAR(10), ERROR_NUMBER()) + ', error message is ' + ERROR_MESSAGE(), 
							   @error_severity = ERROR_SEVERITY(), 
							   @error_state = ERROR_STATE();
						RAISERROR(@msg, @error_severity, @error_state) WITH NOWAIT;

						SET @database = NULL;
	
						WHILE @@TRANCOUNT > 0
							ROLLBACK;
	
					END CATCH;


					/* If we don't find a database to work on, wait for a few seconds */
					IF @database IS NULL

						BEGIN
							IF @Debug = 1 RAISERROR('No databases to back up right now, starting 3 second throttle', 0, 1) WITH NOWAIT;
							WAITFOR DELAY '00:00:03.000';
						END
	
	
					BEGIN TRY
						
						BEGIN
	
							IF @database IS NOT NULL

							/*
							
							Make sure we have a database to work on -- I should make this more robust so we do something if it is NULL, maybe
							
							*/

								
								BEGIN
	
									SET @msg = N'Taking backup of ' + ISNULL(@database, 'UH OH NULL @database');
									IF @Debug = 1 RAISERROR(@msg, 0, 1) WITH NOWAIT;

										/*
										
										Call Ola's proc to backup the database
										
										*/

	
										EXEC master.dbo.DatabaseBackup @Databases = @database, --Database we're working on
																	   @BackupType = 'LOG', --Going for the LOGs
																	   @Directory = @backup_path, --The path we need to back up to
																	   @Verify = 'N', --We don't want to verify these, it eats into job time
																	   @ChangeBackupType = 'Y', --If we need to switch to a FULL because one hasn't been taken
																	   @CheckSum = 'Y', --These are a good idea
																	   @Compress = 'Y', --This is usually a good idea
																	   @LogToTable = 'Y'; --We should do this for posterity
	
										
										/*
										
										Catch any erroneous zones
										
										*/
										
										SELECT @error_number = ERROR_NUMBER(), 
											   @error_severity = ERROR_SEVERITY(), 
											   @error_state = ERROR_STATE();
	
								END; --End call to dbo.DatabaseBackup
	
						END; --End successful check of @database (not NULL)
					
					END TRY
	
					BEGIN CATCH
	
						IF  @error_number IS NOT NULL

						/*
						
						If the ERROR() function returns a number, update the table with it and the last error date.

						Also update the last start time to 1900-01-01 so it gets picked back up immediately -- the query to find a log backup to take sorts by start time

						*/
	
							BEGIN
	
								SET @msg = N'Error number is ' + CONVERT(NVARCHAR(10), ERROR_NUMBER()); 
								RAISERROR(@msg, @error_severity, @error_state) WITH NOWAIT;
								
								SET @msg = N'Updating backup_worker for database ' + ISNULL(@database, 'UH OH NULL @database') + ' for unsuccessful backup';
								RAISERROR(@msg, 0, 1) WITH NOWAIT;
	
								
									UPDATE bw
											SET bw.is_started = 0,
												bw.is_completed = 1,
												bw.last_log_backup_start_time = '19000101',
												bw.error_number = @error_number,
												bw.last_error_date = GETDATE()
									FROM msdbCentral.dbo.backup_worker bw 
									WHERE bw.database_name = @database;


								/*
								
								Set @database back to NULL to avoid variable assignment weirdness
								
								*/

								SET @database = NULL;

										
										/*
										
										Wait around for a second so we're not just spinning wheels -- this only runs if the BEGIN CATCH is triggered by an error

										*/
										
										IF @Debug = 1 RAISERROR('Starting 1 second throttle', 0, 1) WITH NOWAIT;
										
										WAITFOR DELAY '00:00:01.000';

							END; -- End update of unsuccessful backup
	
					END CATCH;
	
					IF  @database IS NOT NULL AND @error_number IS NULL

					/*
						
					If no error, update everything normally
						
					*/

							
						BEGIN
	
							IF @Debug = 1 RAISERROR('Error number IS NULL', 0, 1) WITH NOWAIT;
								
							SET @msg = N'Updating backup_worker for database ' + ISNULL(@database, 'UH OH NULL @database') + ' for successful backup';
							IF @Debug = 1 RAISERROR(@msg, 0, 1) WITH NOWAIT;
	
								
								UPDATE bw
										SET bw.is_started = 0,
											bw.is_completed = 1,
											bw.last_log_backup_finish_time = GETDATE()
								FROM msdbCentral.dbo.backup_worker bw 
								WHERE bw.database_name = @database;

								
							/*
								
							Set @database back to NULL to avoid variable assignment weirdness
								
							*/

							SET @database = NULL;


						END; -- End update for successful backup	
										
				END; -- End @LogShaming WHILE loop

				
		END; -- End successful check for backup_worker and subsequent code

	
	ELSE
	
		BEGIN
	
			RAISERROR('msdbCentral.dbo.backup_worker does not exist, please run setup script', 0, 1) WITH NOWAIT;
			
			RETURN;
		
		END;
RETURN;



END; -- Final END for stored proc

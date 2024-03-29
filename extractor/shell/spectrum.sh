#!/bin/bash

export PGPASSWORD=${REDSHIFT_JDBC_PASSWORD};

# Sprectrum variables from kettle.properties.
REDSHIFT_URL=${REDSHIFT_JDBC_HOST}
REDSHIFT_USER=${REDSHIFT_JDBC_USER_NAME}
REDSHIFT_PORT=${REDSHIFT_JDBC_PORT}
REDSHIFT_DATASET=${REDSHIFT_JDBC_DB}

# Entity.
SCHEMA="${SCHEMA_NAME}"
TABLE="${TABLE_NAME}"

# Hash.
ENTITY_HASH=`echo -n ${TABLE} | md5sum | awk '{print substr($1,1,6)}'`
SCHEMA_HASH=`echo -n ${SCHEMA} | md5sum | awk '{print substr($1,1,6)}'`

# Caminho do bucket.
STORAGE_QUEUE_PATH="s3://${STORAGE_BUCKET}/${SCHEMA_HASH}_${SCHEMA}/${ENTITY_HASH}_${TABLE}/rawfile/queue/"
STORAGE_RECOVERY_QUEUE_PATH="s3://${STORAGE_BUCKET}/disaster_recovery/${SCHEMA_HASH}_${SCHEMA}/${ENTITY_HASH}_${TABLE}/rawfile/queue/"

# Arquivo de dados. 
DATA_FILE="${SCHEMA}_${TABLE}"

# Cria um schema.
schema_check(){
    if [ ${IS_SPECTRUM} = 1 ] ; then
        echo "Running database check at ${SCHEMA}"
    
        # Cria o schema.
        psql -h ${REDSHIFT_URL} -U ${REDSHIFT_USER} -w -d ${REDSHIFT_DATASET} -p ${REDSHIFT_PORT} << EOF
            CREATE EXTERNAL SCHEMA IF NOT EXISTS ${SCHEMA}
            FROM DATA CATALOG
            DATABASE '${SCHEMA}'
            IAM_ROLE '${SPECTRUM_ROLE}'
            CREATE EXTERNAL DATABASE IF NOT EXISTS;
EOF
        error_check
    else
    	echo "Running database check at ${SCHEMA}"
        
        # Cria o database.
        run_on_athena "CREATE DATABASE IF NOT EXISTS ${SCHEMA};"
    fi
}

# Cria uma tabela sem particionamento.
table_check(){
    echo "Preparing table to store ${OUTPUT_FORMAT} files!"

    if [ ${IS_SPECTRUM} = 1 ] && [ ${HAS_ATHENA} = 0 ]; then    
        # Verifica se a tabela existe.
        TABLE_EXISTS=`psql -h ${REDSHIFT_URL} -U ${REDSHIFT_USER} -w -d ${REDSHIFT_DATASET} -p ${REDSHIFT_PORT} -c "SELECT SUM(N) FROM ( SELECT DISTINCT 1 AS N FROM SVV_EXTERNAL_TABLES WHERE SCHEMANAME='${SCHEMA}' AND TABLENAME='${TABLE}' UNION ALL SELECT 0 AS N);" | sed '1,2d' | head -n 1`

        # Cria a tabela e o schema.
        if [ ${TABLE_EXISTS} -eq 0 ]; then
            schema_check

            psql -h ${REDSHIFT_URL} -U ${REDSHIFT_USER} -w -d ${REDSHIFT_DATASET} -p ${REDSHIFT_PORT} << EOF
                CREATE EXTERNAL TABLE ${SCHEMA}.${TABLE}
                (${FIELD_NAME_AND_TYPE_LIST})
                STORED AS ${OUTPUT_FORMAT}
                LOCATION '${STORAGE_QUEUE_PATH}';
EOF
        fi
        error_check    
    else
        # Cria o database.
        schema_check
        
        # Cria a tabela.
        run_on_athena "CREATE EXTERNAL TABLE IF NOT EXISTS ${SCHEMA}.${TABLE} (${FIELD_NAME_AND_TYPE_LIST}) STORED AS ${OUTPUT_FORMAT} LOCATION '${STORAGE_QUEUE_PATH}';"  
    fi
}

# Cria uma tabela particionada.
partitioned_table_check(){
    echo "Preparing partitioned table to store ${OUTPUT_FORMAT} files!"

    if [ ${IS_SPECTRUM} = 1 ] && [ ${HAS_ATHENA} = 0 ]; then        
        # Verifica se a tabela existe.
        TABLE_EXISTS=`psql -h ${REDSHIFT_URL} -U ${REDSHIFT_USER} -w -d ${REDSHIFT_DATASET} -p ${REDSHIFT_PORT} -c "SELECT SUM(N)FROM (SELECT DISTINCT 1 AS N FROM SVV_EXTERNAL_TABLES WHERE SCHEMANAME='${SCHEMA}' AND TABLENAME='${TABLE}' UNION ALL SELECT 0 AS N);"|sed '1,2d'| head -n 1`

        # Cria a tabela e o schema.
        if [ ${TABLE_EXISTS} -eq 0 ]; then
            schema_check

            psql -h ${REDSHIFT_URL} -U ${REDSHIFT_USER} -w -d ${REDSHIFT_DATASET} -p ${REDSHIFT_PORT} << EOF
                CREATE EXTERNAL TABLE ${SCHEMA}.${TABLE}
                (  ${FIELD_NAME_AND_TYPE_LIST}	)
                PARTITIONED BY ( PARTITION_VALUE INT )
                STORED AS ${OUTPUT_FORMAT}
                LOCATION '${STORAGE_QUEUE_PATH}';
EOF
        fi
        error_check    
    else
        # Cria o database.
        schema_check
        
        # Cria a tabela.
        run_on_athena "CREATE EXTERNAL TABLE IF NOT EXISTS ${SCHEMA}.${TABLE} (${FIELD_NAME_AND_TYPE_LIST}) PARTITIONED BY ( partition_value int ) STORED AS ${OUTPUT_FORMAT} LOCATION '${STORAGE_QUEUE_PATH}';"       
    fi
}

# Executa carga particionada.
partition_load(){
	echo "Running partition load!"
	cd ${RAWFILE_QUEUE_PATH}

	#Particiona o arquivo contendo os dados.
	echo "Partitioning data file delimited by ${DELIMITER}!"

    if [ ${MODULE} == "query" ] || [ ${MODULE} == "file" ]; then
		if [ ${DEBUG} = 1 ] ; then
			echo "DEBUG:java -jar ${GLOVE_HOME}/extractor/lib/converter.jar \
				--folder=${RAWFILE_QUEUE_PATH} \
				--filename=*.csv \
				--delimiter=${DELIMITER} \
				--target=csv \
				--partition=0 \
				--header \
				--replace"
		fi

        java -jar ${GLOVE_HOME}/extractor/lib/converter.jar \
			--folder=${RAWFILE_QUEUE_PATH} \
			--filename=*.csv \
			--delimiter=${DELIMITER} \
			--target=csv \
			--partition=0 \
			--header \
			--replace
		error_check
    else
		if [ ${DEBUG} = 1 ] ; then
			echo "DEBUG:java -jar ${GLOVE_HOME}/extractor/lib/converter.jar \
				--folder=${RAWFILE_QUEUE_PATH} \
				--filename=*.csv \
				--delimiter=${DELIMITER} \
				--target=csv \
				--partition=0 \
				--replace"
		fi

        java -jar ${GLOVE_HOME}/extractor/lib/converter.jar \
			--folder=${RAWFILE_QUEUE_PATH} \
			--filename=*.csv \
			--delimiter=${DELIMITER} \
			--target=csv \
			--partition=0 \
			--replace
		error_check
    fi


	# Identifica se será realizado merge.
	if [ ${PARTITION_MERGE} -gt 0 ]; then
		echo "Partition merge ACTIVED!"
    else
        echo "Partition merge DISABLED!"    
	fi

    # Converte os arquivos das partições para formato colunar.
    echo "Generating ${OUTPUT_FORMAT} files!"
	if [ ${DEBUG} = 1 ] ; then
	 	echo "DEBUG:java -jar ${GLOVE_HOME}/extractor/lib/converter.jar \
			--folder=${RAWFILE_QUEUE_PATH} \
			--filename=*.csv \
			--delimiter=${DELIMITER} \
			--schema=${METADATA_JSON_FILE} \
			--target=${OUTPUT_FORMAT} \
			--compression=${OUTPUT_COMPRESSION} \
			--thread=${THREAD} \
			--duplicated=${ALLOW_DUPLICATED} \
			--fieldkey=1 \
			--merge=${PARTITION_MERGE} \
			--bucket=${STORAGE_QUEUE_PATH} \
			--mode=${PARTITION_MODE} \
			--replace"
	fi

    java -jar ${GLOVE_HOME}/extractor/lib/converter.jar \
		--folder=${RAWFILE_QUEUE_PATH} \
		--filename=*.csv \
		--delimiter=${DELIMITER} \
		--schema=${METADATA_JSON_FILE} \
		--target=${OUTPUT_FORMAT} \
		--compression=${OUTPUT_COMPRESSION} \
		--thread=${THREAD} \
		--duplicated=${ALLOW_DUPLICATED} \
		--fieldkey=1 \
		--merge=${PARTITION_MERGE} \
		--bucket=${STORAGE_QUEUE_PATH} \
		--mode=${PARTITION_MODE} \
		--replace
    error_check

    # Identifica se o particionamento é real ou virtual.
    if [ ${PARTITION_MODE} == "real" ]; then
        # Cria o diretório para cada partição respeitando o padrão de particionamento do HIVE.
        for i in `ls *.${OUTPUT_FORMAT}`
        do
            PARTITION=`echo $i | cut -d '.' -f 1`
            mkdir -p ${RAWFILE_QUEUE_PATH}partition_value=${PARTITION}
            rm -f ${RAWFILE_QUEUE_PATH}partition_value=${PARTITION}/*
            mv -f $i ${RAWFILE_QUEUE_PATH}partition_value=${PARTITION}
            error_check
        done
    fi

	# Envia os arquivo para o storage.
	echo "Uploading ${OUTPUT_FORMAT} files!"
	aws s3 cp ${RAWFILE_QUEUE_PATH} ${STORAGE_QUEUE_PATH} --recursive --exclude "*" --include "*.${OUTPUT_FORMAT}" --only-show-errors
	error_check

    # Adiciona as partições na tabela.
	if [ ${PARTITION_MODE} == "real" ]; then
        # Cria o diretório para cada partição respeitando o padrão de particionamento do HIVE.
        for i in `ls`
        do
            PARTITION=`echo $i | cut -d '=' -f 2`

			echo "Adding partition ${PARTITION} to table ${SCHEMA}.${TABLE}!"
            run_on_athena "ALTER TABLE ${SCHEMA}.${TABLE} ADD IF NOT EXISTS PARTITION ( partition_value = '${PARTITION}');"
        done
	fi

    # Remove os arquivos temporários.
    if [ ${DEBUG} = 0 ] ; then
        clean_up
    fi
}

# Executa a carga delta.
delta_load(){
	echo "Running delta load!"
	cd ${RAWFILE_QUEUE_PATH}

    # Identifica se o arquivo existe no storage.
	FILE_EXISTS=`aws s3 ls ${STORAGE_QUEUE_PATH} | grep ${DATA_FILE}. | wc -l`

    if [ ${FILE_EXISTS} -gt 0 ]; then
        # Recupera o arquivo de dados.
        echo "Getting hot file!"
		aws s3 cp ${STORAGE_QUEUE_PATH} ${RAWFILE_QUEUE_PATH} --recursive --exclude "*" --include "${DATA_FILE}.*" --only-show-errors
        error_check
    fi

    # Converte o arquivo final para o formato colunar.
    echo "Generating ${OUTPUT_FORMAT} files!"
	if [ ${DEBUG} = 1 ] ; then
		echo "DEBUG:java -jar ${GLOVE_HOME}/extractor/lib/converter.jar \
			--folder=${RAWFILE_QUEUE_PATH} \
			--filename=${DATA_FILE}.csv \
			--delimiter=${DELIMITER} \
			--schema=${METADATA_JSON_FILE} \
			--target=${OUTPUT_FORMAT} \
			--compression=${OUTPUT_COMPRESSION} \
			--thread=${THREAD} \
			--duplicated=${ALLOW_DUPLICATED} \
			--fieldkey=0 \
			--merge=${PARTITION_MERGE} \
			--bucket=${STORAGE_QUEUE_PATH} \
			--replace"
	fi

    java -jar ${GLOVE_HOME}/extractor/lib/converter.jar \
		--folder=${RAWFILE_QUEUE_PATH} \
		--filename=${DATA_FILE}.csv \
		--delimiter=${DELIMITER} \
		--schema=${METADATA_JSON_FILE} \
		--target=${OUTPUT_FORMAT} \
		--compression=${OUTPUT_COMPRESSION} \
		--thread=${THREAD} \
		--duplicated=${ALLOW_DUPLICATED} \
		--fieldkey=0 \
		--merge=${PARTITION_MERGE} \
		--bucket=${STORAGE_QUEUE_PATH} \
		--replace
    error_check

	# Remove os arquivos antigos.
	aws s3 rm ${STORAGE_QUEUE_PATH} --recursive --exclude "*" --include "${DATA_FILE}.*" --only-show-errors

    # Envia o arquivo para o storage.
    echo "Uploading ${OUTPUT_FORMAT} files to S3 "
    aws s3 cp ${RAWFILE_QUEUE_PATH} ${STORAGE_QUEUE_PATH} --recursive --exclude "*" --include "*.${OUTPUT_FORMAT}" --only-show-errors
    error_check

    # Remove os arquivos temporários.
    if [ ${DEBUG} = 0 ] ; then
        clean_up
    fi
}

# Executa carga full.
full_load(){
	echo "Running full load!"
  	cd ${RAWFILE_QUEUE_PATH}

	# Identifica se o arquivo pode ser quebrado.
	SPLIT=1

	# Identifica se o APPEND está habilitado no módulo de arquivo.
	if [ ${MODULE} == "file" ] && [ ${FILE_OUTPUT_MODE} == "append" ]; then
		SPLIT=0
	fi

	if [ ${SPLIT} == 1 ]; then
		# Quebra o arquivo original em blocos menores.
		echo "Splitting csv file!"
		split -l ${PARTITION_LENGTH} -a 4 --numeric-suffixes=1 --additional-suffix=.csv ${RAWFILE_QUEUE_FILE} ${DATA_FILE}_
		error_check

		# Remove o arquivo original.
		echo "Removing file ${RAWFILE_QUEUE_FILE}!"
		rm -f ${RAWFILE_QUEUE_FILE}
		error_check
	fi

	if [ ${MODULE} == "file" ]; then
		# Converte o arquivo de dados para formato colunar.
    	echo "Generating ${OUTPUT_FORMAT} files!"
		if [ ${DEBUG} = 1 ] ; then
			echo "DEBUG:java -jar ${GLOVE_HOME}/extractor/lib/converter.jar \
				--folder=${RAWFILE_QUEUE_PATH} \
				--filename=*.csv \
				--header \
				--delimiter=${DELIMITER} \
				--schema=${METADATA_JSON_FILE} \
				--target=${OUTPUT_FORMAT} \
				--compression=${OUTPUT_COMPRESSION} \
				--thread=${THREAD} \
				--duplicated=${ALLOW_DUPLICATED} \
				--replace"
		fi

    	java -jar ${GLOVE_HOME}/extractor/lib/converter.jar \
			--folder=${RAWFILE_QUEUE_PATH} \
			--filename=*.csv \
			--header \
			--delimiter=${DELIMITER} \
			--schema=${METADATA_JSON_FILE} \
			--target=${OUTPUT_FORMAT} \
			--compression=${OUTPUT_COMPRESSION} \
			--thread=${THREAD} \
			--duplicated=${ALLOW_DUPLICATED} \
			--replace
    	error_check

		if [ ${FILE_OUTPUT_MODE} == "append" ]; then
			echo "APPEND mode ON!"
		else
			# Remove os arquivos antigo do storage.
			echo "Removing files from ${STORAGE_QUEUE_PATH}"
			aws s3 rm ${STORAGE_QUEUE_PATH} --recursive --only-show-errors
		fi
	else
		# Converte o arquivo de dados para formato colunar.
		echo "Generating ${OUTPUT_FORMAT} files!"
		if [ ${DEBUG} = 1 ] ; then
			echo "DEBUG:java -jar ${GLOVE_HOME}/extractor/lib/converter.jar \
				--folder=${RAWFILE_QUEUE_PATH} \
				--filename=*.csv \
				--delimiter=${DELIMITER} \
				--schema=${METADATA_JSON_FILE} \
				--target=${OUTPUT_FORMAT} \
				--compression=${OUTPUT_COMPRESSION} \
				--thread=${THREAD} \
				--duplicated=${ALLOW_DUPLICATED} \
				--replace"
		fi

		java -jar ${GLOVE_HOME}/extractor/lib/converter.jar \
			--folder=${RAWFILE_QUEUE_PATH} \
			--filename=*.csv \
			--delimiter=${DELIMITER} \
			--schema=${METADATA_JSON_FILE} \
			--target=${OUTPUT_FORMAT} \
			--compression=${OUTPUT_COMPRESSION} \
			--thread=${THREAD} \
			--duplicated=${ALLOW_DUPLICATED} \
			--replace
		error_check

		# Remove os arquivos antigo do storage.
		echo "Removing files from ${STORAGE_QUEUE_PATH}"
		aws s3 rm ${STORAGE_QUEUE_PATH} --recursive --only-show-errors
	fi

    # Envia o arquivo para o storage.
    echo "Uploading ${OUTPUT_FORMAT} files to S3 "
    aws s3 cp ${RAWFILE_QUEUE_PATH} ${STORAGE_QUEUE_PATH} --recursive --exclude "*" --include "*.${OUTPUT_FORMAT}" --only-show-errors
    error_check

    # Remove os arquivos temporários.
    if [ ${DEBUG} = 0 ] ; then        
        clean_up
    fi
}

#Executa uma query no Athena. 
run_on_athena()
{
    QUERY=$1

    if [ ${DEBUG} = 1 ] ; then
        echo ${QUERY}
    fi
    
    # Cria o database.
    ATHENA_QUERY_ID=`aws athena start-query-execution \
            --query-string "${QUERY}" \
            --output text \
            --result-configuration OutputLocation=s3://${STORAGE_BUCKET}/staging`

    # Identifica o status de execução.
    while true
    do
        ATHENA_QUERY_STATUS=`aws athena get-query-execution --query-execution-id $ATHENA_QUERY_ID | jq '.QueryExecution.Status.State' | sed 's/\"//g'`
        error_check

        if [[ "$ATHENA_QUERY_STATUS" == "SUCCEEDED" ]]; then
            break
        elif [[ "$ATHENA_QUERY_STATUS" == "FAILED" || "$ATHENA_QUERY_STATUS" == "CANCELLED" ]]; then
            echo "Fail running ${QUERY} :/"
            exit 1
        else
            # Verifica o status da instrução enquanto diferente de SUCCEEDED, FAILED ou CANCELLED.
            sleep 1
        fi
    done
}

# Realiza a limpeza dos arquivos temporários.
clean_up()
{
    if [ ${MODULE} != "file" ]; then
        echo "Removing temporary folder ${QUEUE_PATH}"
        cd ${GLOVE_TEMP}
        rm -rf ${QUEUE_PATH}
    fi
}

# Realiza o backup dos arquivos brutos.
backup()
{
    #Identifica a data e hora do backup.
    DAY=`date '+%Y-%m-%d'`
    HOUR=`date '+%H%M'`

    #Identifica o bucket que receberá os dados do backup. 
    STORAGE_BACKUP_METADATA_PATH="s3://${STORAGE_BUCKET_BACKUP}/backup/${SCHEMA}/${TABLE}/metadata/day=${DAY}/hour=${HOUR}/"
    STORAGE_BACKUP_QUEUE_PATH="s3://${STORAGE_BUCKET_BACKUP}/backup/${SCHEMA}/${TABLE}/rawfile/queue/day=${DAY}/hour=${HOUR}/"

    # Envia o arquivo do metadado para o storage.
    echo "Backing up metadata files to ${STORAGE_BACKUP_METADATA_PATH}"
    aws s3 cp ${METADATA_PATH} ${STORAGE_BACKUP_METADATA_PATH} --recursive --only-show-errors
    error_check
    
    # Envia o arquivo de dados para o storage.
    echo "Backing up data files to ${STORAGE_BACKUP_QUEUE_PATH}"
    cd ${RAWFILE_QUEUE_PATH}
    pigz -c ${RAWFILE_QUEUE_FILE} > ${RAWFILE_QUEUE_FILE}.gz 
    aws s3 cp ${RAWFILE_QUEUE_PATH} ${STORAGE_BACKUP_QUEUE_PATH} --recursive --exclude "*" --include "*.gz" --only-show-errors
    rm -f ${RAWFILE_QUEUE_FILE}.gz 
    error_check 
}

# Identifica a ocorrência de erros e interrompe processo.
error_check()
{
	if [ $? -gt 0 ]; then
        echo "An error has occurred :_("

        # Remove os arquivos temporários.
        if [ ${DEBUG} = 0 ] ; then
            clean_up
        fi

		exit 1
	fi
}

# Identifica o tamanho do diretório de trabalho.
QUEUE_FOLDER_SIZE=`du -s ${RAWFILE_QUEUE_PATH} | cut -f1`

# Limita o volume de dados.
if [ ${QUEUE_FOLDER_SIZE} -gt ${QUEUE_FILES_SIZE_LIMIT} ]; then
	echo "You are trying processing ${QUEUE_FOLDER_SIZE} KB :0. Please, reduce the amount of data!"

	# Remove os arquivos temporários.
	if [ ${DEBUG} = 0 ] ; then
		clean_up
	fi

	exit 1
else
	echo "${QUEUE_FOLDER_SIZE} KB of data will be processed ( ${QUEUE_FILES_SIZE_LIMIT} KB is the limit )!"
fi

# Identifica se deve recriar a tabela.
if [ ${IS_RECREATE} = 1 -o ${IS_RELOAD} = 1 ]; then

    DATE=`date '+%Y%m%d%H%M%S'`

    # Cria o arquivo de recuperação a partir dos arquivos do processo.
    echo "Moving files to recovery folder ${STORAGE_RECOVERY_QUEUE_PATH}!"
    aws s3 mv ${STORAGE_QUEUE_PATH} ${STORAGE_RECOVERY_QUEUE_PATH}${DATE}/ --recursive --only-show-errors

	if [ ${IS_RELOAD} = 0 ]; then
		# Dropa a tabela para que possa ser recriada.         
        if [ ${IS_SPECTRUM} = 1 ] && [ ${HAS_ATHENA} = 0 ]; then
            echo "Dropping table ${SCHEMA}.${TABLE} from Spectrum!"
            psql -h ${REDSHIFT_URL} -U ${REDSHIFT_USER} -w -d ${REDSHIFT_DATASET} -p ${REDSHIFT_PORT} << EOF
			     drop table ${SCHEMA}.${TABLE};
EOF
        else
            echo "Dropping table ${SCHEMA}.${TABLE} from Athena!"
            run_on_athena "DROP TABLE IF EXISTS ${SCHEMA}.${TABLE};"    
        fi

		# Realiza a verificação da estrutura das tabelas.
		if [ "${#PARTITION_FIELD}" -gt "0" ] ; then
			if [ ${PARTITION_MODE} == "real" ]; then
				partitioned_table_check
			else
				table_check
			fi
		else
			table_check
		fi
	fi
fi

# Identifica a quantidade de arquivos a serem processados.
QUEUE_FILE_COUNT=`cat ${RAWFILE_QUEUE_PATH}*${DATA_FILE}* |wc -l`

# Executa o processo de carga e criação de entidades.
if [ ${QUEUE_FILE_COUNT} -gt 0 ]; then
	echo "Work area:"
	echo "${RAWFILE_QUEUE_PATH}"

    if [ ${IS_SPECTRUM} = 1 ] ; then
        echo "Credentials:"
        echo "URL ${REDSHIFT_URL}"
        echo "User ${REDSHIFT_USER}"
        echo "Dataset ${REDSHIFT_DATASET}"
        echo "Port ${REDSHIFT_PORT}"
        echo "Password provided by kettle.properties parameter"
    fi

    # Identifica se será feito bachup dos arquivos de dados. 
    if [ "${#STORAGE_BUCKET_BACKUP}" -gt "0" ]; then
        backup
    fi

	schema_check

    # Identifica se é uma named query.
    if [ ${MODULE} == "query" ]; then

		# Identifica se deve exportar o csv intermediário para o storage.
		if [ ${IS_EXPORT} = 1 ]; then

			# Compacta o arquivo csv.
			pigz -c ${RAWFILE_QUEUE_FILE} > ${RAWFILE_QUEUE_FILE}.gz

			# Define o storage de exportação.
			if [ "${#EXPORT_BUCKET}" -gt "0" ]; then
				# Envia o arquivo para o storage.
				echo "Exporting resultset to ${EXPORT_BUCKET}!"
				aws s3 rm ${EXPORT_BUCKET}${RAWFILE_QUEUE_FILE}.gz --recursive --only-show-errors
				aws s3 cp ${RAWFILE_QUEUE_FILE}.gz ${EXPORT_BUCKET} --only-show-errors
				error_check

				# Remove o arquivo compactado do diretório.
				rm -rf ${RAWFILE_QUEUE_FILE}.gz

				# Finaliza o processo de exportação.
				if [ ${ONLY_EXPORT} = 1 ]; then
					echo "Exporting finished!"
					exit 0
				fi
			else
				echo "EXPORT_BUCKET was not defined!"
			fi
		fi
    fi


    # Identifica se a fonte é arquivo.
    if [ ${MODULE} == "file" ]; then
		# Identifica o tipo de carga que será realizado.
		if [ ${FILE_INPUT_PARTITONED} == 1 ]; then
			partition_load
		else
			full_load
		fi
    else
	    # Identifica o tipo de carga que será realizado.
	    if [ "${#PARTITION_FIELD}" -gt "0" ]; then
		    partition_load
	    else
            if [ "${#DELTA_FIELD_IN_METADATA}" -gt "0" ]; then
			    delta_load
		    else
                # Remove o header do csv intermediário.
                if [ ${MODULE} == "query" ]; then
                    echo "Removing header from ${RAWFILE_QUEUE_FILE}!"
                    tail -n +2 ${RAWFILE_QUEUE_FILE} > ${RAWFILE_QUEUE_FILE}.tmp
                    mv -f ${RAWFILE_QUEUE_FILE}.tmp ${RAWFILE_QUEUE_FILE};
                fi

			    full_load
		    fi
	    fi
    fi

	# Identifica a quantidade de registros na tabela.
    ATHENA_QUERY_ID=`aws athena start-query-execution --query-string "select count(1) from ${SCHEMA}.${TABLE};" --output text --result-configuration OutputLocation=s3://${STORAGE_BUCKET}/staging`
    error_check

    while true
    do
        # Identifica o status da query.
        ATHENA_QUERY_STATUS=`aws athena get-query-execution --query-execution-id $ATHENA_QUERY_ID | jq '.QueryExecution.Status.State' | sed 's/\"//g'`
        error_check

        if [[ "$ATHENA_QUERY_STATUS" == "SUCCEEDED" ]]; then
            ROW_COUNT=`aws athena get-query-results --query-execution-id=$ATHENA_QUERY_ID --output=text --query=ResultSet.Rows | sed '1d'| grep -E '[0-9]' | tr -d '[:alpha:][:blank:]'`
            error_check

            # Atualiza as estatísticas da entidade.
            if [ ${IS_SPECTRUM} = 1 ] ; then
                if [ ${ROW_COUNT} -gt 0 ]; then
                    echo "Updating table properties: ${ROW_COUNT} records!"
                    psql -h ${REDSHIFT_URL} -U ${REDSHIFT_USER} -w -d ${REDSHIFT_DATASET} -p ${REDSHIFT_PORT} << EOF
                      ALTER TABLE ${SCHEMA}.${TABLE} SET TABLE PROPERTIES ('numRows'='${ROW_COUNT}');
EOF
                fi
                
                echo "Removing old table versions from glue!"
                TABLE_VERSION=`aws glue get-table-versions --max-items=100 --database-name ${SCHEMA} --table-name ${TABLE} | jq --compact-output "[.TableVersions[].VersionId]" | sed -e 's/\,/ /g;s/\[/ /g;s/\]/ /g;s/\"//g'`
                aws glue batch-delete-table-version --database-name ${SCHEMA} --table-name ${TABLE} --version-ids $TABLE_VERSION               
            else
                echo "${ROW_COUNT} records in the table ${SCHEMA}.${TABLE}"   
            fi

            break
        elif [[ "$ATHENA_QUERY_STATUS" == "FAILED" || "$ATHENA_QUERY_STATUS" == "CANCELLED" ]]; then
            echo "Table properties not updated :/"
            break
        else
            sleep 5
        fi
    done   
else
	echo "Nothing to load from ${RAWFILE_QUEUE_PATH} :/"
fi

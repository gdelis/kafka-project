# From Zero to Hero with Kafka Connect

## Running the test rig

1. Bring up the stack
```sh
  docker-compose up -d
```

2. Wait for Kafka Connect to be started
```sh
    bash -c ' \
    echo -e "\n\n=============\nWaiting for Kafka Connect to start listening on localhost ⏳\n=============\n"
    while [ $(curl -s -o /dev/null -w %{http_code} http://localhost:8083/connectors) -ne 200 ] ; do
    echo -e "\t" $(date) " Kafka Connect listener HTTP state: " $(curl -s -o /dev/null -w %{http_code} http://localhost:8083/connectors) " (waiting for 200)"
    sleep 5  
    done
    echo -e $(date) "\n\n--------------\n\o/ Kafka Connect is ready! Listener HTTP state: " $(curl -s -o /dev/null -w %{http_code} http://localhost:8083/connectors) "\n--------------\n"
    '
```

3. Make sure that the Elasticsearch, Debezium, and Neo4j connectors are available:
```sh
  curl -s localhost:8083/connector-plugins|jq '.[].class'|egrep 'Neo4jSinkConnector|MySqlConnector|ElasticsearchSinkConnector'
```

Expect:
```sh
    "io.confluent.connect.elasticsearch.ElasticsearchSinkConnector"
    "io.debezium.connector.mysql.MySqlConnector"
    "streams.kafka.connect.sink.Neo4jSinkConnector"
```

4. Get a MySQL prompt
```sh
  docker exec -it mysql bash -c 'mysql -u root -p$MYSQL_ROOT_PASSWORD demo'
```

## Demo 1 - Kafka Connect pipelines

A MySQL database stores orders placed by an application.

* Kafka Connect - Debezium MySQL connector streams them into Kafka topic
* Kafka Connect - Elasticsearch connector to stream orders from Kafka topic to both Elasticsearch and Neo4j

### Ingest data from a database

#### Look at the DB:
```sh
  SELECT * FROM ORDERS ORDER BY CREATE_TS DESC LIMIT 1\G
```

Trigger the MySQL data generator with:
```sh
  docker exec mysql /data/02_populate_more_orders.sh
```

Look at the new rows!
```sh
  watch -n 1 -x docker exec -t mysql bash -c 'echo "SELECT * FROM ORDERS ORDER BY CREATE_TS DESC LIMIT 1 \G" | mysql -u root -p$MYSQL_ROOT_PASSWORD demo'
```

#### Create the connector

```sh
    curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/source-debezium-orders-00/config \
    -d '{
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "database.hostname": "mysql",
    "database.port": "3306",
    "database.user": "debezium",
    "database.password": "dbz",
    "database.server.id": "42",
    "database.server.name": "asgard",
    "table.whitelist": "demo.orders",
    "database.history.kafka.bootstrap.servers": "broker:29092",
    "database.history.kafka.topic": "dbhistory.demo" ,
    "decimal.handling.mode": "double",
    "include.schema.changes": "true",
    "transforms": "unwrap,addTopicPrefix",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.addTopicPrefix.type":"org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.addTopicPrefix.regex":"(.*)",
    "transforms.addTopicPrefix.replacement":"mysql-debezium-$1"
    }'
```

Check the status of the connector

```sh
    # Apache Kafka >=2.3
    curl -s "http://localhost:8083/connectors?expand=info&expand=status" | \
    jq '. | to_entries[] | [ .value.info.type, .key, .value.status.connector.state,.value.status.tasks[].state,.value.info.config."connector.class"]|join(":|:")' | \
    column -s : -t| sed 's/\"//g'| sort
```

Output should be

```sh
    source  |  source-debezium-orders-00  |  RUNNING  |  RUNNING  |  io.debezium.connector.mysql.MySqlConnector
```

View the topic in the CLI:

```sh
    docker exec kafkacat kafkacat \
    -b broker:29092 \
    -r http://schema-registry:8081 \
    -s avro \
    -t mysql-debezium-asgard.demo.ORDERS \
    -C -o -10 -q | jq '.id, .CREATE_TS.string'
```

Show Kafka Consumer and MySQL side by side.

=== Stream data from Kafka to Elasticsearch

```sh
    curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/sink-elastic-orders-00/config \
    -d '{
    "connector.class": "io.confluent.connect.elasticsearch.ElasticsearchSinkConnector",
    "topics": "mysql-debezium-asgard.demo.ORDERS",
    "connection.url": "http://elasticsearch:9200",
    "type.name": "type.name=kafkaconnect",
    "key.ignore": "true",
    "schema.ignore": "true"
    }'
```

=== Stream to Neo4j

```sh
    curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/sink-neo4j-orders-00/config \
    -d '{
    "connector.class": "streams.kafka.connect.sink.Neo4jSinkConnector",
    "topics": "mysql-debezium-asgard.demo.ORDERS",
    "neo4j.server.uri": "bolt://neo4j:7687",
    "neo4j.authentication.basic.username": "neo4j",
    "neo4j.authentication.basic.password": "connect",
    "neo4j.topic.cypher.mysql-debezium-asgard.demo.ORDERS": "MERGE (city:city{city: event.delivery_city}) MERGE (customer:customer{id: event.customer_id, delivery_address: event.delivery_address, delivery_city: event.delivery_city, delivery_company: event.delivery_company}) MERGE (vehicle:vehicle{make: event.make, model:event.model}) MERGE (city)<-[:LIVES_IN]-(customer)-[:BOUGHT{order_total_usd:event.order_total_usd,order_id:event.id}]->(vehicle)"
    } '
```

=== View in Elasticsearch

http://localhost:5601/app/kibana#/discover?_g=(refreshInterval:(pause:!f,value:5000),time:(from:now-15m,mode:quick,to:now))&_a=(columns:!(id,delivery_address,delivery_city,delivery_company,make,model,order_total_usd),index:mysql-debezium-asgard.demo.orders,interval:auto,query:(language:lucene,query:''),sort:!(CREATE_TS,desc))[Inspect the data in Kibana] or from CLI:

```sh
    curl -s http://localhost:9200/mysql-debezium-asgard.demo.orders/_search \
    -H 'content-type: application/json' \
    -d '{ "size": 5, "sort": [ { "CREATE_TS": { "order": "desc" } } ] }' |\
    jq '.hits.hits[]._source | .id, .CREATE_TS'
```

[NOTE]
====
If you want to set the Elasticsearch document id to match the key of the source database record use the following:

```sh
    "key.ignore": "true",
    "transforms": "extractKey",
    "transforms.extractKey.type":"org.apache.kafka.connect.transforms.ExtractField$Key",
    "transforms.extractKey.field":"id"
```
====

=== View in Neo4j

View in http://localhost:7474/browser/[Neo4j browser] (login `neo4j`/`connect`)


== [Optional] Show off ksqlDB

```sh
  docker exec -it ksqldb ksql http://localhost:8088
```

```sh
    SET 'auto.offset.reset' = 'earliest';
    SHOW TOPICS;
    CREATE STREAM ORDERS WITH (KAFKA_TOPIC='mysql-debezium-asgard.demo.ORDERS', VALUE_FORMAT='AVRO');
    DESCRIBE ORDERS;
    SELECT ID, MAKE, MODEL, CREATE_TS FROM ORDERS EMIT CHANGES;
```

Filter

```sh
    SET 'auto.offset.reset' = 'earliest';
    SELECT ID, MAKE, MODEL, CREATE_TS FROM ORDERS WHERE MAKE='Ford' EMIT CHANGES;
```

Aggregates

```sh
    SELECT MAKE, COUNT(*), SUM(CAST(ORDER_TOTAL_USD AS DECIMAL(13,2)))
    FROM ORDERS
    GROUP BY MAKE EMIT CHANGES;
    
    SELECT TIMESTAMPTOSTRING(WINDOWSTART,'HH:mm:ssZ','Europe/Brussels') AS WINDOW_START_TS,
    MAKE, COUNT(*) AS ORDER_COUNT, SUM(CAST(ORDER_TOTAL_USD AS DECIMAL(13,2))) AS TOTAL_VALUE_USD
    FROM ORDERS WINDOW TUMBLING (SIZE 5 MINUTES)
    WHERE MAKE='Ford'
    GROUP BY MAKE EMIT CHANGES;
```

"Pull" query

```sh
    CREATE TABLE ORDERS_BY_HOUR AS
    SELECT TIMESTAMPTOSTRING(WINDOWSTART,'yyyy-MM-dd''T''HH:mm:ssZ','Europe/London') AS WINDOW_START_TS,
    MAKE, COUNT(*) AS ORDER_COUNT, SUM(ORDER_TOTAL_USD) AS TOTAL_VALUE_USD
    FROM ORDERS WINDOW TUMBLING (SIZE 1 HOUR)
    GROUP BY MAKE EMIT CHANGES;
    
    -- Push query
    SELECT TIMESTAMPTOSTRING(WINDOWSTART,'HH:mm:ssZ','Europe/Brussels') AS TS, MAKE, ORDER_COUNT, TOTAL_VALUE_USD
    FROM ORDERS_BY_HOUR
    WHERE ROWKEY='Ford'
    EMIT CHANGES;
    
    -- Pull query
    SELECT TIMESTAMPTOSTRING(WINDOWSTART,'HH:mm:ssZ','Europe/Brussels') AS TS, MAKE, ORDER_COUNT, TOTAL_VALUE_USD
    FROM ORDERS_BY_HOUR
    WHERE ROWKEY='Ford';
```

REST API

```sh
    docker exec -t ksqldb curl -s -X "POST" "http://localhost:8088/query" \
    -H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
    -d '{"ksql":"SELECT TIMESTAMPTOSTRING(WINDOWSTART,'\''yyyy-MM-dd HH:mm:ss'\'','\''Europe/London'\'') AS TS, MAKE, ORDER_COUNT, TOTAL_VALUE_USD FROM ORDERS_BY_HOUR WHERE ROWKEY='\''Ford'\'';"}'|jq -c '.'
```

Connector creation

```sh
    SHOW CONNECTORS;
    
    CREATE SINK CONNECTOR SINK_ES_AGG WITH (
    'connector.class' = 'io.confluent.connect.elasticsearch.ElasticsearchSinkConnector',
    'topics'          = 'ORDERS_BY_HOUR',
    'connection.url'  = 'http://elasticsearch:9200',
    'type.name'       = 'type.name=kafkaconnect',
    'key.ignore'      = 'false',
    'schema.ignore'   = 'true'
    );
    
    SHOW CONNECTORS;
```

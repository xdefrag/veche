CREATE TABLE "request" (
    "id" INTEGER PRIMARY KEY,
    "user" INTEGER NOT NULL
        REFERENCES "user" ON DELETE RESTRICT ON UPDATE RESTRICT,
    "comment" INTEGER NOT NULL
        REFERENCES "comment" ON DELETE RESTRICT ON UPDATE RESTRICT,
    "fulfilled" BOOLEAN NOT NULL,
    "issue" INTEGER NOT NULL
        REFERENCES "issue" ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT "unique_request" UNIQUE ("user","comment")
);

CREATE TABLE "stellar_holder" (
    "id" INTEGER PRIMARY KEY,
    "asset" VARCHAR NOT NULL,
    "key" VARCHAR NOT NULL,
    CONSTRAINT "unique_holder" UNIQUE ("asset","key")
);

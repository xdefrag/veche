{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module Handler.Topic
    ( getTopicEditR
    , getTopicNewR
    , getTopicR
    , getTopicsR
    , postTopicR
    , postTopicsR
    ) where

import Import

import Database.Persist.Sql (rawSql)
import Text.Julius (rawJS)
import Yesod.Form.Bootstrap3 (BootstrapFormLayout (BootstrapBasicForm), bfs,
                              renderBootstrap3)

import Handler.Comment (CommentMaterialized (..), commentWidget)
import Types (CommentType (..))

data TopicMaterialized = TopicMaterialized
    { topic     :: Topic
    , comments  :: [CommentMaterialized]
    , lastEdit  :: TopicVersion
    }

loadTopicComments :: TopicId -> SqlPersistT Handler [CommentMaterialized]
loadTopicComments topicId = do
    comments <-
        rawSql
            "SELECT ??, ??\
            \ FROM Comment, User ON Comment.author == User.id\
            \ WHERE Comment.topic == ?"
            [toPersistValue topicId]
    pure
        [ CommentMaterialized{..}
        | (Entity _ comment, Entity _ author) <- comments
        ]

loadTopic :: TopicId -> SqlPersistT Handler TopicMaterialized
loadTopic topicId = do
    topic@Topic{topicAuthor, topicCreated, topicCurVersion} <- get404 topicId
    versionId <-
        topicCurVersion
        ?| lift (constraintFail "Topic.current_version must be valid")
    author <-
        get topicAuthor
        ?|> lift (constraintFail "Topic.author must exist in User table")
    comments' <- loadTopicComments topicId
    let startingPseudoComment =
            CommentMaterialized
                { comment =
                    Comment
                        { commentAuthor     = topicAuthor
                        , commentCreated    = topicCreated
                        , commentMessage    = ""
                        , commentParent     = Nothing
                        , commentTopic      = topicId
                        , commentType       = CommentStart
                        }
                , author
                }
    let comments = startingPseudoComment : comments'
    lastEdit <-
        get versionId
        ?|> lift
                (constraintFail
                    "Topic.current_version must exist in TopicVersion table")
    pure TopicMaterialized{..}

(?|) :: Applicative f => Maybe a -> f a -> f a
Nothing ?| action   = action
Just x  ?| _        = pure x

(?|>) :: Monad f => f (Maybe a) -> f a -> f a
m ?|> k = m >>= (?| k)

getTopicR :: TopicId -> Handler Html
getTopicR topicId = do
    TopicMaterialized{comments, topic, lastEdit} <- runDB $ loadTopic topicId
    let Topic{topicTitle, topicOpen} = topic
    let TopicVersion{topicVersionBody} = lastEdit
    commentFormId <- newIdent
    commentListId <- newIdent
    commentTextareaId <- newIdent
    defaultLayout $(widgetFile "topic")

data TopicContent = TopicContent{title, body :: Text}

topicForm :: Maybe TopicContent -> AForm Handler TopicContent
topicForm previousContent = do
    title <-
        areq
            textField
            (bfs ("Title" :: Text)){fsName = Just "title"}
            (title <$> previousContent)
    body <-
        unTextarea <$>
        areq
            textareaField
            (bfs ("Message" :: Text)){fsName = Just "body"}
            (Textarea . body <$> previousContent)
    pure TopicContent{..}

getTopicNewR :: Handler Html
getTopicNewR = do
    (formWidget, formEnctype) <-
        generateFormPost $
        renderBootstrap3 BootstrapBasicForm $ topicForm Nothing
    defaultLayout $(widgetFile "topic-new")

getTopicsR :: Handler Html
getTopicsR = do
    mState <- lookupGetParam "state"
    let stateOpen = mState /= Just "closed"
    (openTopicCount, closedTopicCount, topics) <-
        runDB $
            (,,)
            <$> count [TopicOpen ==. True]
            <*> count [TopicOpen ==. False]
            <*> selectList [TopicOpen ==. stateOpen] []
    defaultLayout $(widgetFile "topics")

postTopicsR :: Handler Html
postTopicsR = do
    ((result, formWidget), formEnctype) <-
        runFormPost $ renderBootstrap3 BootstrapBasicForm $ topicForm Nothing
    case result of
        FormSuccess topic -> do
            topicId <- addTopic topic
            redirect $ TopicR topicId
        _ -> defaultLayout $(widgetFile "topic-new")

  where

    addTopic :: TopicContent -> Handler TopicId
    addTopic TopicContent{title, body} = do
        now <- liftIO getCurrentTime
        user <- requireAuthId
        runDB do
            let topic = Topic
                    { topicTitle        = title
                    , topicAuthor       = user
                    , topicOpen         = True
                    , topicCreated      = now
                    , topicCurVersion   = Nothing
                    }
            topicId <- insert topic
            let version = TopicVersion
                    { topicVersionTopic     = topicId
                    , topicVersionBody      = body
                    , topicVersionCreated   = now
                    , topicVersionAuthor    = user
                    }
            versionId <- insert version
            update topicId [TopicCurVersion =. Just versionId]
            pure topicId

data StateAction = Close | Reopen

postTopicR :: TopicId -> Handler Html
postTopicR topicId = do
    mAction <- lookupPostParam "action"
    case mAction of
        Just "close"  -> closeReopenTopic Close  topicId
        Just "reopen" -> closeReopenTopic Reopen topicId
        Just "edit"   -> editTopic               topicId
        _ -> invalidArgs ["action must be one of: close, reopen, edit"]

editTopic :: TopicId -> Handler Html
editTopic topicId = do
    ((result, formWidget), formEnctype) <-
        runFormPost $ renderBootstrap3 BootstrapBasicForm $ topicForm Nothing
    case result of
        FormSuccess content -> do
            addTopicVersion content
            redirect $ TopicR topicId
        _ -> defaultLayout $(widgetFile "topic-edit")

  where

    addTopicVersion :: TopicContent -> Handler ()
    addTopicVersion TopicContent{title, body} = do
        now <- liftIO getCurrentTime
        user <- requireAuthId
        runDB do
            topic <- get404 topicId
            authorizeTopicModification topic user
            let version = TopicVersion
                    { topicVersionAuthor    = user
                    , topicVersionBody      = body
                    , topicVersionCreated   = now
                    , topicVersionTopic     = topicId
                    }
            versionId <- insert version
            update
                topicId
                [TopicTitle =. title, TopicCurVersion =. Just versionId]
            insert_
                Comment
                    { commentAuthor     = user
                    , commentCreated    = now
                    , commentMessage    = ""
                    , commentParent     = Nothing
                    , commentTopic      = topicId
                    , commentType       = CommentEdit
                    }

closeReopenTopic :: StateAction -> TopicId -> Handler a
closeReopenTopic action topicId = do
    now <- liftIO getCurrentTime
    user <- requireAuthId
    runDB do
        topic <- get404 topicId
        authorizeTopicModification topic user
        update
            topicId
            [ TopicOpen
                =.  case action of
                        Close  -> False
                        Reopen -> True
            ]
        insert_
            Comment
                { commentAuthor     = user
                , commentCreated    = now
                , commentMessage    = ""
                , commentParent     = Nothing
                , commentTopic      = topicId
                , commentType       =
                    case action of
                        Close   -> CommentClose
                        Reopen  -> CommentReopen
                }
    redirect $ TopicR topicId

authorizeTopicModification :: MonadHandler m => Topic -> UserId -> m ()
authorizeTopicModification Topic{topicAuthor} user =
    when (topicAuthor /= user) $ permissionDenied "Not authorized"

getTopicEditR :: TopicId -> Handler Html
getTopicEditR topicId = do
    content <-
        runDB do
            Topic{topicTitle, topicCurVersion} <- get404 topicId
            versionId <-
                topicCurVersion
                ?| lift (constraintFail "Topic.current_version must be valid")
            TopicVersion{topicVersionBody} <-
                get versionId
                ?|> lift
                        (constraintFail
                            "Topic.current_version must exist\
                            \ in TopicVersion table")
            pure TopicContent{title = topicTitle, body = topicVersionBody}
    (formWidget, formEnctype) <-
        generateFormPost $
        renderBootstrap3 BootstrapBasicForm $ topicForm $ Just content
    defaultLayout $(widgetFile "topic-edit")

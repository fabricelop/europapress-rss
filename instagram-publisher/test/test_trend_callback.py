import importlib
import json
import os
import unittest
from unittest.mock import patch

os.environ.setdefault("TTENDENCIAS_BOT_TOKEN","123456789:dummy-test-token")
bot=importlib.import_module("trends.telegram_bot")


class Response:
    def __init__(self, obj):
        self.obj=obj
    def __enter__(self):return self
    def __exit__(self,*args):return None
    def read(self):return json.dumps(self.obj).encode("utf-8")


class TrendCallbackTests(unittest.TestCase):
    def setUp(self):
        self.cb={
            "id":"cb123","data":"tx:i:abc123:1",
            "message":{
                "chat":{"id":42},"message_id":1234,
                "reply_markup":{"inline_keyboard":[
                    [{"text":"📸 Publicar en Instagram","callback_data":"tx:i:abc123:1"}],
                    [{"text":"✅ Publicado","callback_data":"tx:p:abc123:1"},
                     {"text":"🗑️ Desestimar","callback_data":"tx:d:abc123:1"}]
                ]}
            }
        }
        self.delivery={
            "event_id":"abc123","revision":1,"telegram_message_id":1234,
            "status":"sent","instagram":{
                "image_url":"https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/instagram-images/example.jpg",
                "caption":"Texto exacto"}
        }
    def test_callback_never_closes_x_actions(self):
        def load(path,fallback):
            if path.endswith("telegram-bot-state.json"):return {"chat_id":42}
            if path.endswith("telegram-image-deliveries.json"):return {"items":[self.delivery]}
            raise AssertionError(path)
        with (patch.object(bot,"load_remote_json",side_effect=load),
              patch.object(bot,"call") as call,
              patch.object(bot.urllib.request,"urlopen",return_value=Response({
                  "ok":True,"state":"published",
                  "permalink":"https://www.instagram.com/p/testpost/"
              })) as urlopen,
              patch.dict(os.environ,{
                  "INSTAGRAM_PUBLISHER_URL":"https://publisher.example",
                  "INSTAGRAM_INTERNAL_SECRET":"a"*40
              })):
            self.assertTrue(bot.handle_instagram_package_callback(self.cb))
        data=json.loads(urlopen.call_args.args[0].data)
        self.assertEqual(data["event_id"],"abc123")
        self.assertEqual(data["caption"],"Texto exacto")
        changes=[x for x in call.call_args_list if x.args[0]=="editMessageReplyMarkup"]
        self.assertEqual(len(changes),1)
        rows=changes[0].args[1]["reply_markup"]["inline_keyboard"]
        self.assertEqual(rows[0][0]["url"],"https://www.instagram.com/p/testpost/")
        self.assertEqual(rows[1][0]["callback_data"],"tx:p:abc123:1")
        self.assertEqual(rows[1][1]["callback_data"],"tx:d:abc123:1")
        self.assertFalse(any(x.args[0]=="deleteMessage" for x in call.call_args_list))

    def test_same_package_router_in_web_and_legacy_modes(self):
        with (patch.object(bot,"handle_instagram_package_callback",return_value=True) as ig,
              patch.object(bot,"handle_package_callback",return_value=True) as x):
            self.assertTrue(bot.route_package_callback(self.cb))
            ig.assert_called_once_with(self.cb)
            x.assert_not_called()
            self.cb["data"]="tx:p:abc123:1"
            self.assertTrue(bot.route_package_callback(self.cb))
            x.assert_called_once_with(self.cb)
            self.cb["data"]="tx:d:abc123:1"
            self.assertTrue(bot.route_package_callback(self.cb))
            self.assertEqual(x.call_count,2)
            self.assertEqual(ig.call_count,1)

    def test_web_mode_packages_use_the_instagram_aware_router(self):
        import inspect
        source=inspect.getsource(bot.poll_packages)
        self.assertIn("route_package_callback(cb)",source)
        self.assertNotIn("handle_package_callback(cb)",source)

    def test_unlinked_message_not_publishable(self):
        self.cb["message"]["message_id"]=9999
        def load(path, fallback):
            if path.endswith("telegram-bot-state.json"):return {"chat_id":42}
            if path.endswith("telegram-image-deliveries.json"):return {"items":[self.delivery]}
            raise AssertionError(path)
        with (patch.object(bot,"load_remote_json",side_effect=load),
              patch.object(bot,"call") as call,
              patch.object(bot.urllib.request,"urlopen") as urlopen,
              patch.dict(os.environ,{"INSTAGRAM_PUBLISHER_URL":"https://publisher.example",
                                     "INSTAGRAM_INTERNAL_SECRET":"a"*40})):
            self.assertTrue(bot.handle_instagram_package_callback(self.cb))
        urlopen.assert_not_called()
        self.assertFalse(any(x.args[0]=="deleteMessage" for x in call.call_args_list))


if __name__=="__main__":
    unittest.main()

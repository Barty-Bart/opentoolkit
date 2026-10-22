import json, sys, threading, unittest
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Voice'))
from local_writing import rewrite, available_models, endpoint_url, WritingUnavailable

class LocalWritingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.requests=[];cls.response={'choices':[{'message':{'content':'• Ship the update tomorrow.'},'finish_reason':'stop'}]}
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                body=json.dumps({'data':[{'id':'local-instruct'}]}).encode();self.send_response(200);self.end_headers();self.wfile.write(body)
            def do_POST(self):
                cls.requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                if cls.response=='redirect':
                    self.send_response(302);self.send_header('Location','http://example.com/leak');self.end_headers();return
                body=json.dumps(cls.response).encode();self.send_response(200);self.end_headers();self.wfile.write(body)
            def log_message(self,*args):pass
        cls.server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        cls.endpoint=f'http://127.0.0.1:{cls.server.server_port}/v1'
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start()
    @classmethod
    def tearDownClass(cls):cls.server.shutdown();cls.server.server_close();cls.thread.join()
    def setUp(self):
        type(self).response={'choices':[{'message':{'content':'• Ship the update tomorrow.'},'finish_reason':'stop'}]}
        self.config={'aiWritingEnabled':True,'aiWritingEndpoint':self.endpoint,'aiWritingModel':'local-instruct'}
    def test_summary_round_trip_and_model_listing(self):
        self.assertEqual(available_models(self.endpoint),['local-instruct'])
        self.assertEqual(rewrite('We should ship tomorrow. Tomorrow is the plan.','summary',self.config),'• Ship the update tomorrow.')
        request=self.requests[-1]
        self.assertFalse(request['stream']);self.assertEqual(request['model'],'local-instruct')
        self.assertIn('bullet',request['messages'][0]['content'])
    def test_email_task_is_different_and_keeps_original_material(self):
        rewrite('Hi Alex, the update is ready.','email_ai',self.config)
        self.assertIn('email draft',self.requests[-1]['messages'][0]['content'])
        self.assertEqual(self.requests[-1]['messages'][1]['content'],'Hi Alex, the update is ready.')
    def test_remote_urls_credentials_and_redirects_are_rejected(self):
        for url in ('https://api.example.com/v1','http://example.com','file:///tmp/data','http://user:password@localhost:1234/v1','http://localhost/v1?token=secret','http://127.0.0.1.evil.test/v1'):
            with self.subTest(url=url),self.assertRaises(WritingUnavailable):endpoint_url(url,'models')
        type(self).response='redirect'
        with self.assertRaises(WritingUnavailable):rewrite('Synthetic text','summary',self.config)
    def test_disabled_or_missing_model_never_makes_request(self):
        with patch('local_writing.request_json') as request:
            for config in ({},{'aiWritingEnabled':True}):
                with self.assertRaises(WritingUnavailable):rewrite('Text','summary',config)
            request.assert_not_called()
    def test_empty_truncated_or_tool_responses_fail_safely(self):
        for choice in ({'message':{'content':''}}, {'message':{'content':'partial'},'finish_reason':'length'}, {'message':{'content':'answer','tool_calls':[{}]}}):
            type(self).response={'choices':[choice]}
            with self.assertRaises(WritingUnavailable):rewrite('Text','summary',self.config)
    def test_plain_modes_do_not_call_a_model(self):
        with patch('local_writing.request_json') as request:
            self.assertEqual(rewrite('Keep my words','verbatim',self.config),'Keep my words');request.assert_not_called()

if __name__=='__main__':unittest.main()

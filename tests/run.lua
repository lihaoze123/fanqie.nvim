-- nvim --headless -u NONE -i NONE -l tests/run.lua (from the plugin directory)
local root=vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1,"S").source:sub(2),":p")))
vim.opt.rtp:prepend(root)
local function test()
  local P=require("fanqie.parser")
  local A=require("fanqie.align")
  local md5=require("fanqie.protocol.md5").sum
  local vectors={
    {"","d41d8cd98f00b204e9800998ecf8427e"}, {"a","0cc175b9c0f1b6a831c399e269772661"},
    {"abc","900150983cd24fb0d6963f7d28e17f72"},
    {"message digest","f96b697d7cb7938d525a2f31aaf161d0"},
    {"abcdefghijklmnopqrstuvwxyz","c3fcd3d76192e4007dfb496cca67e13b"},
    {string.rep("a",1000000),"7707d6ae4e027c70eea2a935c2296f21"},
  }
  for _,v in ipairs(vectors) do assert(md5(v[1])==v[2],"MD5 vector failed") end
  assert(P.title("一百四十三章 交易").number==143)
  assert(P.title("第554章 用心").name==P.title("第五百五十四章 用心").name)
  assert(P.title("第五百零五章 标题").number==505)
  assert(not P.title("这里的文章不能当作章节"))
  local lines={"书名","","引子","序文","","第1章 开始","第一段。","第二段。","","第2章 后续","后续文字"}
  local chapters=P.parse(lines)
  assert(#chapters==3 and P.at(chapters,8)==chapters[2])
  local paras=P.paragraphs(lines,chapters[2],"line")
  assert(#paras==2 and paras[1].line==7)
  assert(A.find(paras,"<p> 第一段。 </p>").line==7)
  assert(not A.find(paras,"无关段落"))
  local dup=P.paragraphs({"第1章 重复","重复。","重复。"},{line=1,last=3},"line")
  assert(not A.find(dup,"重复。") and not A.resolve(dup,{hash=dup[1].hash}))
  local merged=P.paragraphs({"第1章 X","前半","后半","","另一段"},{line=1,last=5},"blank")
  assert(#merged==2 and merged[1].last==3 and merged[1].text=="前半后半")
  local directory={{id="11",title="第一章 开始"},{id="12",title="第二章 后续"}}
  assert(P.match_chapter(chapters[2],directory).id=="11")
  assert(not P.match_chapter({number=624,name="适中"},{{id="1",title="第六百二十四章 台岗"}}))
  assert(not P.match_chapter(chapters[2],{{id="1",title="第一章 开始"},{id="2",title="第一章 开始"}}))
  local C=require("fanqie.protocol.comments")
  local tree=C.build_reply_tree({{reply_id="a",parent_reply_id="b"},{reply_id="b",parent_reply_id="a"}})
  assert(#tree==1 and #tree[1].children==1,"cyclic replies must not disappear")
  assert(require("fanqie.protocol.crypto").build_common_query({install_id="1",device_id="2"}).aid=="1967")
  local calls={}
  local wrong_source=false
  package.loaded["fanqie.api"]={
    setup=function() end,cancel=function() end,
    request=function(action,args,opts,cb)
      calls[#calls+1]={action=action,args=args}
      if action=="stats" then cb({["0"]={count=1},["1"]={count=3}},nil,{cached=false})
      elseif action=="comments" then
        local source=args.para==0 and "第一段。" or "第二段。"
        if wrong_source then source="不匹配的另一版段落" end
        cb({comments={{comment_id="c"..args.para,para_index=args.para,para_src_content=source,
          text="测试评论\n第二行",user_name="测试用户",digg_count=2,reply_count=1,images={}}},
          total=3,cursor=args.cursor=="" and "1" or "2",has_more=args.cursor==""},nil,{cached=false})
      elseif action=="replies" then
        cb({comments={{reply_id="r",text="回复正文",user_name="回复者",images={}}},cursor="1",has_more=false,total=1})
      else error("unexpected API call "..action) end
    end,
  }
  local temp=vim.fn.tempname(); vim.fn.mkdir(temp,"p")
  local file=temp.."/sample.txt"; vim.fn.writefile(lines,file)
  local F=require("fanqie")
  F.setup({state_dir=temp.."/state",cache_dir=temp.."/cache",restore_position=false})
  vim.cmd.edit(file)
  local buf=vim.api.nvim_get_current_buf()
  vim.wo.wrap=false; vim.wo.linebreak=false
  local s=F.enable()
  assert(vim.wo.wrap and vim.wo.linebreak)
  local other=vim.api.nvim_create_buf(true,false)
  vim.api.nvim_win_set_buf(s.win,other)
  assert(not vim.wo.wrap and not vim.wo.linebreak,"reading options must not leak to another buffer")
  vim.api.nvim_win_set_buf(s.win,buf)
  assert(vim.wo.wrap and vim.wo.linebreak,"reading options must return when the TXT is shown again")
  assert(#calls==0,"unbound buffers must not send requests")
  s.book.binding={id="123",title="测试书",author="作者"}; s.book.directory=directory
  F.command("next")
  assert(s.remote.id=="11" and vim.tbl_count(s.resolved)==2)
  local ns=vim.api.nvim_create_namespace("fanqie.paragraphs")
  assert(#vim.api.nvim_buf_get_extmarks(buf,ns,0,-1,{})==2)
  vim.api.nvim_win_set_cursor(s.win,{7,0})
  F.command("uncalibrate")
  assert(not s.resolved["0"])
  wrong_source=true
  F.command("comments")
  assert(not s.resolved["0"] and s.view.mode=="unknown","offset alone must never verify a paragraph")
  wrong_source=false
  vim.api.nvim_set_current_win(s.win)
  F.command("comments")
  assert(s.resolved["0"] and s.view.para=="0","candidate lookup must verify the returned quote")
  local panel=s.panel
  assert(panel and vim.api.nvim_buf_is_valid(panel.buf))
  assert(table.concat(vim.api.nvim_buf_get_lines(panel.buf,0,-1,false),"\n"):find("测试评论",1,true))
  local enter=vim.fn.maparg("<CR>","n",false,true).callback
  local comment_row
  for row,item in pairs(panel.rows) do if item.kind=="comment" then comment_row=row; break end end
  vim.api.nvim_win_set_cursor(panel.win,{comment_row,0}); enter()
  assert(table.concat(vim.api.nvim_buf_get_lines(panel.buf,0,-1,false),"\n"):find("回复正文",1,true))
  F.command("unmatched")
  assert(table.concat(vim.api.nvim_buf_get_lines(panel.buf,0,-1,false),"\n"):find("没有未对齐",1,true))
  require("fanqie.ui").close(s)
  vim.api.nvim_set_current_win(s.win); vim.api.nvim_win_set_cursor(s.win,{8,0})
  local old_input=vim.ui.input
  vim.ui.input=function(_,cb) cb("测试书签") end
  F.command("bookmark"); vim.ui.input=old_input
  assert(#s.book.bookmarks==1)
  F.disable(buf)
  assert(not vim.wo.wrap and not vim.wo.linebreak,"window options must be restored on disable")
  assert(#vim.api.nvim_buf_get_extmarks(buf,ns,0,-1,{})==0)
  assert(vim.deep_equal(vim.fn.readfile(file),lines),"plugin must not change TXT bytes")
  local stored=require("fanqie.storage").read(s.path)
  assert(stored.position.line==8 and #stored.bookmarks==1)
  local restored=F.enable(buf)
  assert(restored.book.binding.id=="123")
  F.disable(buf)
  print("PASS: MD5, chapter parsing/matching, safe alignment, cyclic replies, reader UI, comments/replies, bookmarks, persistence, TXT unchanged")
end
local ok,err=xpcall(test,debug.traceback)
if not ok then io.stderr:write(err.."\n"); vim.cmd("cquit 1") end

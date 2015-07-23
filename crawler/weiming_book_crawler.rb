require 'crawler_rocks'

require 'json'
require 'iconv'
require 'book_toolkit'

require 'pry'

require 'thread'
require 'thwait'

class WeimingBookCrawler
  include CrawlerRocks::DSL

  def initialize update_progress: nil, after_each: nil
    @update_progress_proc = update_progress
    @after_each_proc = after_each

    @query_url = "http://www.wmbook.com.tw/index.php"
    # @ic = Iconv.new("utf-8//IGNORE//translit","utf-8")
  end

  def books
    @books = {}
    @threads = []

    visit @query_url

    r = RestClient.post(@query_url + "?php_mode=search", {
      "kindid" => nil,
      "kind" => " 書籍類別",
      "name" => nil,
      "serial" => nil,
      "isbn" => nil,
      "author" => nil,
      "publisher" => nil,
      "Submit" => "送出",
    }, cookies: @cookies) { |response, request, result, &block|
      if [301, 302, 307].include? response.code
        response.follow_redirection(request, result, &block)
      else
        response.return!(request, result, &block)
      end
    }

    r = get_page(0)
    doc = Nokogiri::HTML(r)

    page_num = doc.xpath('//input[@name="Input"]/parent::td').text.match(/共(\d+)頁/)[1].to_i

    finished_page = 0

    (1..page_num).each do |i|
      sleep(1) until (
        @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        @threads.count < (ENV['MAX_THREADS'] || 20)
      )
      @threads << Thread.new do
        start_book_id = (i - 1) * 30
        r = get_page start_book_id
        doc = Nokogiri::HTML(r)

        doc.xpath(
          '//table[@width="563"][@border="0"][@cellpadding="0"][@cellspacing="0"][@align="LEFT"]/tr[@onmouseover]'
        ).each do |row|
          datas = row.xpath('td')

          edition = datas[2] && datas[2].text.to_i
          edition = nil if edition == 0

          url = URI.join(@query_url, datas[0] && datas[0].xpath('a/@href').to_s).to_s
          id = url.match(/(?<=id=)\d+/).to_s

          price = datas[4] && datas[4].text.gsub(/[^\d]/, '').to_i

          @books[id] = {
            name: datas[0] && datas[0].text,
            author: datas[1] && datas[1].text.strippp,
            edition: edition,
            year: datas[3] && datas[3].text.to_i,
            url: url,
            original_price: price,
            known_supplier: 'weiming'
          }
        end
        finished_page += 1
        print "#{finished_page} / #{page_num}\n"
      end # end new Thread
    end

    ThreadsWait.all_waits(*@threads)

    detail_finish_count = 0
    books_count = @books.keys.count

    # crawl isbn, blah blah blah...
    @threads = []
    @books.each_with_index do |(id, book), i|
      sleep(1) until (
        @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        @threads.count < (ENV['MAX_THREADS'] || 20)
      )
      @threads << Thread.new do
        r = RestClient.get book[:url]
        doc = Nokogiri::HTML(r)

        img_url = doc.xpath('//img[contains(@src, "upload/bookimg")]/@src').to_s
        external_image_url = URI.join(@query_url, img_url).to_s

        rows_selector = '//table[@width="516"][@border="0"][@cellpadding="0"][@cellspacing="0"][@align="center"]/tr'
        rows_data = doc.xpath(rows_selector).map{|row| row.text.strip}

        internal_code_row = rows_data.find{|d| d.match(/(?<=書號[：:]).+/)}
        internal_code = internal_code_row && internal_code_row.match(/(?<=書號[：:]).+/).to_s

        isbn_row = rows_data.find{|d| d.match(/ISBN[：:]/)}
        isbn = nil; invalid_isbn = nil;
        isbn = isbn_row && isbn_row.match(/(?<=ISBN[：:]).+/).to_s

        begin
          isbn = BookToolkit.to_isbn13(isbn)
        rescue Exception => e
          invalid_isbn = isbn
          isbn = nil
        end

        publisher_row = rows_data.find{|d| d.match(/出版商[：:].+/)}
        publisher = publisher_row && publisher_row.match(/(?<=出版商[：:]).+/).to_s

        book[:internal_code] = internal_code
        book[:publisher] = publisher
        book[:isbn] = isbn
        book[:invalid_isbn] = invalid_isbn

        @after_each_proc.call(book: book) if @after_each_proc

        detail_finish_count += 1
        # print "#{detail_finish_count} / #{books_count}\n"
      end # end Thread do
    end
    ThreadsWait.all_waits(*@threads)

    @books.values
  end

  def get_page start_book_id
    RestClient.get( @query_url + "?" + {
      "php_mode" => 'booklist',
      "StartBookId" => start_book_id,
    }.map{|k, v| "#{k}=#{v}"}.join('&'),
      cookies: @cookies
    )
  end
end

class String
  def strippp
    self.gsub(/^\u{20}+/, '').gsub(/\u{20}+$/, '')
  end
end

# cc = WeimingBookCrawler.new
# File.write('wm_books.json', JSON.pretty_generate(cc.books))

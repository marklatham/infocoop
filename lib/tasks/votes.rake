namespace :votes do

  desc "Tally votes for the next day."
  task tally: :environment do
    
    # Tally cutoff_time is the next midnight after the last tally cutoff time,
    # which should be the same in both current and archived standings tables.
    # cutoff_time must also be before Time.now.
    
    Time.zone = "Pacific Time (US & Canada)"
    time_now = Time.now
    puts "Time now = " + time_now.inspect
    standing_tallied_at = Standing.maximum(:tallied_at) if Standing.any?
    past_standing_tallied_at = PastStanding.maximum(:tallied_at) if PastStanding.any?
    puts "standing_tallied_at = " + standing_tallied_at.to_s
    puts "past_standing_tallied_at = " + past_standing_tallied_at.to_s
    
    if standing_tallied_at
      latest_tallied_at = standing_tallied_at
      if past_standing_tallied_at
        unless standing_tallied_at == past_standing_tallied_at # Normal case is ==
          puts "Warning: standing_tallied_at = " + standing_tallied_at.to_s
          puts "not same as past_standing_tallied_at = " + past_standing_tallied_at.to_s
          if standing_tallied_at > past_standing_tallied_at
            puts "Current standings seem not archived => archiving..."
            for standing in Standing.all
              standing.archive
            end
          else # i.e. standing_tallied_at < past_standing_tallied_at
            latest_tallied_at = past_standing_tallied_at
            puts "Warning: archived standings later than current standings."
          end
        end
      else # i.e. past_standing_tallied_at does not exist
        puts "Warning: no past_standing_tallied_at found."
      end
    else # i.e. standing_tallied_at does not exist
      puts "Warning: no standing_tallied_at found."
    end
    
    if latest_tallied_at
      # Usually 24 hours to next cutoff, but this allows +- 12 hours for unusual situations:
      next_day = 36.hours.since(latest_tallied_at)
    else
      # If no prior tally output exists, default to next_day = now:
      next_day = time_now
    end
    # Set cutoff_time = the midnight before next_day:
    cutoff_time = Time.new(next_day.year, next_day.month, next_day.day, 0, 0, 0)
    puts "Tally cutoff = " + cutoff_time.inspect
    
    if cutoff_time > time_now
      puts "It's too soon to tally!"
    else
      calc_standings(cutoff_time)  # ***MAIN ROUTINE: Method defined below.
    end
    # This mailer works in dev but not in prod. Haven't really tried to fix it, because
    # we get emails from cron job in prod anyway:
    AdminMailer.votes_tally(cutoff_time).deliver
  end
  
  
  # Subroutine to calculate channel standings from votes:
  def calc_standings(cutoff_time)
    
    parameter = {days_full_value: 10, days_valid: 60, interpolation_range: 10.0, spread: 8.0}
    votes = Vote.where("user_id IS NOT NULL and created_at < ?", cutoff_time)
                .order(:user_id, :channel_id, created_at: :desc).to_a
    standings = Standing.all.to_a
    unless standings.any?
      puts "Warning: no standings found. Generating them from displayed channels."
      channels = Channel.where("display_id > 0")
      if channels.any?
        for channel in channels
          Standing.create!(channel_id: channel.id, share: 1.0)
        end
        standings = Standing.all.to_a
      else
        puts "Alert: no standings or displayed channels -- nothing to do!  :-("
        return
      end
      
    end
    
    if votes.any?
      puts "Found " + votes.size.to_s + " votes. "
    else
      puts "Found no votes. "
    end
    
    # Only count the latest vote from each user on each channel.
    # For each [user_id, channel_id], votes are in reverse chronological order,
    # so keep the first one in each group:
    keep_vote = votes[0]
    index = 1
    while votes[index]  # i.e. until we have gone past the end of votes array
      if votes[index].user_id ==  keep_vote.user_id &&  votes[index].channel_id == keep_vote.channel_id
        votes.delete(votes[index])
      else
        keep_vote = votes[index]
        index += 1
      end
    end
    
    if votes.any?
      puts votes.size.to_s + " latest votes for tallying."
    end
    
    if standings.any?
      puts "Found " + standings.size.inspect + " standings."
    else
      puts "Alert: Found no standings!"
      return
    end
    
    # Make sure shares are nonnegative whole numbers, not all zero:
    for standing in standings
      standing.share = standing.share.round
      if standing.share < 0.0
        standing.share = 0.0
      end
    end
    
    if standings.sum(&:share) <= 0.0
      for standing in standings
        standing.share = 1.0
      end
    end
    
    # Calculate count0 (# votes for share or more) and count1 (# votes for share+1 or more) for each standing:
    for standing in standings
      standing.count0 = count_votes(cutoff_time, votes, standing, 0.0, parameter)
      standing.count1 = count_votes(cutoff_time, votes, standing, 1.0, parameter)
      puts standing.channel.name + " Count0: " + standing.count0.inspect
      puts standing.channel.name + " Count1: " + standing.count1.inspect
    end
    
    # standing_to_increase is the standing record that most deserves to have its share increased by 1:
    standing_to_increase = standings.max{|a,b| a.count1 <=> b.count1 }
    # Can only reduce a share if it's positive, so:
    standings_pos = standings.find_all {|s| s.share > 0.0 }
    # standing_to_decrease is the standing record that most deserves to have its share decreased by 1:
    standing_to_decrease = standings_pos.min {|a,b| a.count0 <=> b.count0 }
    
    # If shares sum to more than 100 (which shouldn't happen, but just in case), decrease 1 at a time:
    while standings.sum(&:share) > 100.0
      standing_to_decrease.share -= 1.0
      standing_to_decrease.count1 = standing_to_decrease.count0
      standing_to_decrease.count0 = count_votes(cutoff_time, votes, standing_to_decrease, 0.0, parameter)
      
    #  standing_to_increase = standings.max{ |a,b| a.count1 <=> b.count1 }
      standings_pos = standings.find_all{ |s| s.share > 0.0 }
      standing_to_decrease = standings_pos.min{ |a,b| a.count0 <=> b.count0 }
    end
    standing_to_increase = standings.max{ |a,b| a.count1 <=> b.count1 }
    
    # If shares sum to less than 100 (e.g. when first website[s] added), increase 1 at a time:
    while standings.sum(&:share) < 100.0
      standing_to_increase.share += 1.0
      standing_to_increase.count0 = standing_to_increase.count1
      standing_to_increase.count1 = count_votes(cutoff_time, votes, standing_to_increase, 1.0, parameter)
      
      standing_to_increase = standings.max{ |a,b| a.count1 <=> b.count1 }
    #  standings_pos = standings.find_all{ |s| s.share > 0.0 }
    #  standing_to_decrease = standings_pos.min{ |a,b| a.count0 <=> b.count0 }
    end
    standings_pos = standings.find_all{ |s| s.share > 0.0 }
    standing_to_decrease = standings_pos.min{ |a,b| a.count0 <=> b.count0 }
    
    # ***MAIN LOOP: Adjust shares until highest count1 <= lowest count0
    # i.e. find a cutoff number of votes (actually a range of cutoffs)
    # where shares sum to 100.0 using that same cutoff to determine each website's share.
    # This is like a stock market order matching system. Each count1 is a bid; each count0 is an offer.
    # If the highest bid is higher than the lowest offer, then a trade of 1% happens:
    
    while standing_to_decrease.count0 < standing_to_increase.count1
      # Move one percent share from standing_to_decrease to standing_to_increase:
      
      standing_to_decrease.share -= 1.0
      standing_to_decrease.count1 = standing_to_decrease.count0
      standing_to_decrease.count0 = count_votes(cutoff_time, votes, standing_to_decrease, 0.0, parameter)
      
      standing_to_increase.share += 1.0
      standing_to_increase.count0 = standing_to_increase.count1
      standing_to_increase.count1 = count_votes(cutoff_time, votes, standing_to_increase, 1.0, parameter)
      
      standings_pos = standings.find_all{ |r| r.share > 0.0 }
      standing_to_decrease = standings_pos.min{ |a,b| a.count0 <=> b.count0 }
      standing_to_increase = standings.max{ |a,b| a.count1 <=> b.count1 }
    end
    
    # Share calculations are now completed, so sort & store standings:
    standings.sort! do |a,b|
      [b.share, b.count1, b.created_at] <=> [a.share, a.count1, a.created_at]
    end
    rank_sequence = 0
    for standing in standings
      rank_sequence += 1
      standing.rank = rank_sequence
      standing.tallied_at = cutoff_time
      standing.save     # => Standings table
      standing.archive  # => PastStandings table
    end
    
  end
  
  
  # Subroutine to count (time-decayed) votes for shares >= cutoff_share = standing.share + increment:
  def count_votes(cutoff_time, votes, standing, increment, parameter)
    
    cutoff_share = standing.share + increment
    
    count = 0.0
    for vote in votes
      if vote.channel_id == standing.channel_id && vote.share
        
        # Time decay of vote:
        days_old = (cutoff_time.to_date - vote.created_at.to_date).to_i
        if days_old < parameter[:days_full_value]
          decayed_weight = 1.0
        elsif days_old < parameter[:days_valid]
          decayed_weight = ( parameter[:days_valid] - days_old ) /
                           ( parameter[:days_valid] - parameter[:days_full_value] )
        else
          decayed_weight = 0.0
        end
        
        if vote.share < 0.1
          # This is to catch the special case of vote.share = 0.0 -- no interpolation.
          if cutoff_share < 0.1
            support_fraction = 1.0
          else
            support_fraction = 0.0
          end
        elsif vote.share > cutoff_share + 0.5*parameter[:interpolation_range]
          support_fraction = 1.0
        elsif vote.share < cutoff_share - 0.5*parameter[:interpolation_range]
          support_fraction = 0.0
        else
          support_fraction = 0.5 + ( (vote.share - cutoff_share) / parameter[:interpolation_range] )
        end
        
        count += decayed_weight * support_fraction
      end
    end
    
    # This is designed to encourage competition by handicapping larger shares:
    adjusted_count = count / ( parameter[:spread]**(cutoff_share*0.01) )
    puts standing.channel.name + " adjusted count at share = " + standing.share.to_s +
                      " & increment = " + increment.to_s + " is " + adjusted_count.to_s
    return adjusted_count
  end
  
end
